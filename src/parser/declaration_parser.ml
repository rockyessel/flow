(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module Ast = Flow_ast
open Token
open Parser_common
open Parser_env
open Flow_ast
open Comment_attachment

module type DECLARATION = sig
  val async : env -> bool * Loc.t Comment.t list

  val generator : env -> bool * Loc.t Comment.t list

  val variance : env -> parse_readonly:bool -> bool -> bool -> Loc.t Variance.t option

  val function_params : await:bool -> yield:bool -> env -> (Loc.t, Loc.t) Ast.Function.Params.t

  val function_body :
    env ->
    async:bool ->
    generator:bool ->
    expression:bool ->
    simple_params:bool ->
    (Loc.t, Loc.t) Function.body * bool

  val strict_post_check :
    env ->
    contains_use_strict:bool ->
    (Loc.t, Loc.t) Identifier.t option ->
    (Loc.t, Loc.t) Ast.Function.Params.t ->
    unit

  val let_ :
    env ->
    (Loc.t, Loc.t) Statement.VariableDeclaration.Declarator.t list
    * Loc.t Ast.Comment.t list
    * (Loc.t * Parse_error.t) list

  val const :
    env ->
    (Loc.t, Loc.t) Statement.VariableDeclaration.Declarator.t list
    * Loc.t Ast.Comment.t list
    * (Loc.t * Parse_error.t) list

  val var :
    env ->
    (Loc.t, Loc.t) Statement.VariableDeclaration.Declarator.t list
    * Loc.t Ast.Comment.t list
    * (Loc.t * Parse_error.t) list

  val _function : env -> (Loc.t, Loc.t) Statement.t

  val enum_declaration : ?leading:Loc.t Comment.t list -> env -> (Loc.t, Loc.t) Statement.t
end

module Declaration (Parse : Parser_common.PARSER) (Type : Type_parser.TYPE) : DECLARATION = struct
  module Enum = Enum_parser.Enum (Parse)

  let check_param =
    let rec pattern ((env, _) as check_env) (loc, p) =
      Pattern.(
        match p with
        | Object o -> _object check_env o
        | Array arr -> _array check_env arr
        | Identifier id -> identifier_pattern check_env id
        | Expression _ ->
          error_at env (loc, Parse_error.ExpectedPatternFoundExpression);
          check_env
      )
    and _object check_env o = List.fold_left object_property check_env o.Pattern.Object.properties
    and object_property check_env =
      let open Pattern.Object in
      function
      | Property (_, property) ->
        Property.(
          let check_env =
            match property.key with
            | Identifier id -> identifier_no_dupe_check check_env id
            | _ -> check_env
          in
          pattern check_env property.pattern
        )
      | RestElement (_, { Pattern.RestElement.argument; comments = _ }) ->
        pattern check_env argument
    and _array check_env arr = List.fold_left array_element check_env arr.Pattern.Array.elements
    and array_element check_env =
      let open Pattern.Array in
      function
      | Hole _ -> check_env
      | Element (_, { Element.argument; default = _ }) -> pattern check_env argument
      | RestElement (_, { Pattern.RestElement.argument; comments = _ }) ->
        pattern check_env argument
    and identifier_pattern check_env { Pattern.Identifier.name = id; _ } = identifier check_env id
    and identifier (env, param_names) ((loc, { Identifier.name; comments = _ }) as id) =
      if SSet.mem name param_names then error_at env (loc, Parse_error.StrictParamDupe);
      let (env, param_names) = identifier_no_dupe_check (env, param_names) id in
      (env, SSet.add name param_names)
    and identifier_no_dupe_check (env, param_names) (loc, { Identifier.name; comments = _ }) =
      if is_restricted name then strict_error_at env (loc, Parse_error.StrictParamName);
      if is_future_reserved name || is_strict_reserved name then
        strict_error_at env (loc, Parse_error.StrictReservedWord);
      (env, param_names)
    in
    pattern

  let strict_post_check env ~contains_use_strict id params =
    let strict_mode = Parser_env.in_strict_mode env in
    let simple = is_simple_parameter_list params in
    let (_, { Ast.Function.Params.params; rest; this_ = _; comments = _ }) = params in
    (* If we were already in strict mode and therefore already threw strict
       errors, we want to do these checks outside of strict mode. If we
       were in non-strict mode but the function contains "use strict", then
       we want to do these checks in strict mode *)
    let env =
      if strict_mode then
        with_strict false env
      else
        with_strict contains_use_strict env
    in
    if contains_use_strict || strict_mode || not simple then (
      (match id with
      | Some (loc, { Identifier.name; comments = _ }) ->
        if is_restricted name then strict_error_at env (loc, Parse_error.StrictFunctionName);
        if is_future_reserved name || is_strict_reserved name then
          strict_error_at env (loc, Parse_error.StrictReservedWord)
      | None -> ());
      let acc =
        List.fold_left
          (fun acc (_, { Function.Param.argument; default = _ }) -> check_param acc argument)
          (env, SSet.empty)
          params
      in
      match rest with
      | Some (_, { Function.RestParam.argument; comments = _ }) -> ignore (check_param acc argument)
      | None -> ()
    )

  let function_params =
    let rec param =
      with_loc (fun env ->
          if Peek.token env = T_THIS then error env Parse_error.ThisParamMustBeFirst;
          let argument = Parse.pattern env Parse_error.StrictParamName in
          let default =
            if Peek.token env = T_ASSIGN then (
              Expect.token env T_ASSIGN;
              Some (Parse.assignment env)
            ) else
              None
          in
          { Function.Param.argument; default }
      )
    and param_list env acc =
      match Peek.token env with
      | (T_EOF | T_RPAREN | T_ELLIPSIS) as t ->
        let rest =
          if t = T_ELLIPSIS then
            let leading = Peek.comments env in
            let (loc, id) =
              with_loc
                (fun env ->
                  Expect.token env T_ELLIPSIS;
                  Parse.pattern env Parse_error.StrictParamName)
                env
            in
            Some
              ( loc,
                {
                  Function.RestParam.argument = id;
                  comments = Flow_ast_utils.mk_comments_opt ~leading ();
                }
              )
          else
            None
        in
        if Peek.token env <> T_RPAREN then error env Parse_error.ParameterAfterRestParameter;
        (List.rev acc, rest)
      | _ ->
        let the_param = param env in
        if Peek.token env <> T_RPAREN then Expect.token env T_COMMA;
        param_list env (the_param :: acc)
    in
    let this_param_annotation env =
      if should_parse_types env && Peek.token env = T_THIS then (
        let leading = Peek.comments env in
        let (this_loc, this_param) =
          with_loc
            (fun env ->
              Expect.token env T_THIS;
              if Peek.token env <> T_COLON then begin
                error env Parse_error.ThisParamAnnotationRequired;
                None
              end else
                Some (Type.annotation env))
            env
        in
        match this_param with
        | None -> None
        | Some annot ->
          if Peek.token env = T_COMMA then Eat.token env;
          Some
            ( this_loc,
              {
                Ast.Function.ThisParam.annot;
                comments = Flow_ast_utils.mk_comments_opt ~leading ();
              }
            )
      ) else
        None
    in
    fun ~await ~yield ->
      with_loc (fun env ->
          let env =
            env
            |> with_allow_await await
            |> with_allow_yield yield
            |> with_in_formal_parameters true
          in
          let leading = Peek.comments env in
          Expect.token env T_LPAREN;
          let this_ = this_param_annotation env in
          let (params, rest) = param_list env [] in
          let internal = Peek.comments env in
          Expect.token env T_RPAREN;
          let trailing = Eat.trailing_comments env in
          {
            Ast.Function.Params.params;
            rest;
            comments = Flow_ast_utils.mk_comments_with_internal_opt ~leading ~trailing ~internal ();
            this_;
          }
      )

  let function_body env ~async ~generator ~expression ~simple_params =
    let env = enter_function env ~async ~generator ~simple_params in
    let (body_block, contains_use_strict) = Parse.function_block_body env ~expression in
    (Function.BodyBlock body_block, contains_use_strict)

  let variance env ~parse_readonly is_async is_generator =
    let loc = Peek.loc env in
    let variance =
      match Peek.token env with
      | T_PLUS ->
        let leading = Peek.comments env in
        Eat.token env;
        Some
          ( loc,
            { Variance.kind = Variance.Plus; comments = Flow_ast_utils.mk_comments_opt ~leading () }
          )
      | T_MINUS ->
        let leading = Peek.comments env in
        Eat.token env;
        Some
          ( loc,
            {
              Variance.kind = Variance.Minus;
              comments = Flow_ast_utils.mk_comments_opt ~leading ();
            }
          )
      | T_IDENTIFIER { raw = "readonly"; _ } when parse_readonly ->
        let leading = Peek.comments env in
        Eat.token env;
        Some
          ( loc,
            {
              Variance.kind = Variance.Readonly;
              comments = Flow_ast_utils.mk_comments_opt ~leading ();
            }
          )
      | _ -> None
    in
    match variance with
    | Some (loc, _) when is_async || is_generator ->
      error_at env (loc, Parse_error.UnexpectedVariance);
      None
    | _ -> variance

  let generator env =
    if Peek.token env = T_MULT then (
      let leading = Peek.comments env in
      Eat.token env;
      (true, leading)
    ) else
      (false, [])

  (* Returns true and consumes a token if the token is `async` and the token after it is on
     the same line (see https://tc39.github.io/ecma262/#sec-async-function-definitions) *)
  let async env =
    if Peek.token env = T_ASYNC && not (Peek.ith_is_line_terminator ~i:1 env) then
      let leading = Peek.comments env in
      let () = Eat.token env in
      (true, leading)
    else
      (false, [])

  let _function =
    with_loc (fun env ->
        let (async, leading_async) = async env in
        let (sig_loc, (generator, tparams, id, params, return, predicate, leading)) =
          with_loc
            (fun env ->
              let leading_function = Peek.comments env in
              Expect.token env T_FUNCTION;
              let (generator, leading_generator) = generator env in
              let leading = List.concat [leading_async; leading_function; leading_generator] in
              let (tparams, id) =
                match (in_export_default env, Peek.token env) with
                | (true, T_LPAREN) -> (None, None)
                | (true, T_LESS_THAN) ->
                  let tparams = type_params_remove_trailing env (Type.type_params env) in
                  let id =
                    if Peek.token env = T_LPAREN then
                      None
                    else
                      let id =
                        id_remove_trailing
                          env
                          (Parse.identifier ~restricted_error:Parse_error.StrictFunctionName env)
                      in
                      Some id
                  in
                  (tparams, id)
                | _ ->
                  let id =
                    if Peek.is_identifier env then
                      id_remove_trailing
                        env
                        (Parse.identifier ~restricted_error:Parse_error.StrictFunctionName env)
                    else (
                      (* don't consume the identifier here like Parse.identifier does. *)
                      error_nameless_declaration env "function";
                      (Peek.loc env, { Identifier.name = ""; comments = None })
                    )
                  in
                  let tparams = type_params_remove_trailing env (Type.type_params env) in
                  (tparams, Some id)
              in
              let params =
                let params = function_params ~await:async ~yield:generator env in
                if Peek.token env = T_COLON then
                  params
                else
                  function_params_remove_trailing env params
              in
              let (return, predicate) = Type.annotation_and_predicate_opt env in
              let (return, predicate) =
                match predicate with
                | None -> (type_annotation_hint_remove_trailing env return, predicate)
                | Some _ -> (return, predicate_remove_trailing env predicate)
              in
              (generator, tparams, id, params, return, predicate, leading))
            env
        in
        let simple_params = is_simple_parameter_list params in
        let (body, contains_use_strict) =
          function_body env ~async ~generator ~expression:false ~simple_params
        in
        strict_post_check env ~contains_use_strict id params;
        Statement.FunctionDeclaration
          {
            Function.id;
            params;
            body;
            generator;
            async;
            predicate;
            return;
            tparams;
            sig_loc;
            comments = Flow_ast_utils.mk_comments_opt ~leading ();
          }
    )

  let variable_declaration_list =
    let variable_declaration env =
      let (loc, (decl, err)) =
        with_loc
          (fun env ->
            let id = Parse.pattern env Parse_error.StrictVarName in
            let (init, err) =
              if Eat.maybe env T_ASSIGN then
                (Some (Parse.assignment env), None)
              else
                match id with
                | (_, Ast.Pattern.Identifier _) -> (None, None)
                | (loc, _) -> (None, Some (loc, Parse_error.NoUninitializedDestructuring))
            in
            (Ast.Statement.VariableDeclaration.Declarator.{ id; init }, err))
          env
      in
      ((loc, decl), err)
    in
    let rec helper env decls errs =
      let (decl, err) = variable_declaration env in
      let decls = decl :: decls in
      let errs =
        match err with
        | Some x -> x :: errs
        | None -> errs
      in
      if Eat.maybe env T_COMMA then
        helper env decls errs
      else
        (List.rev decls, List.rev errs)
    in
    (fun env -> helper env [] [])

  let declarations token env =
    let leading = Peek.comments env in
    Expect.token env token;
    let (declarations, errs) = variable_declaration_list env in
    (declarations, leading, errs)

  let var = declarations T_VAR

  let const env =
    let env = env |> with_no_let true in
    let (declarations, leading_comments, errs) = declarations T_CONST env in
    (* Make sure all consts defined are initialized *)
    let errs =
      List.fold_left
        (fun errs decl ->
          match decl with
          | (loc, { Statement.VariableDeclaration.Declarator.init = None; _ }) ->
            (loc, Parse_error.NoUninitializedConst) :: errs
          | _ -> errs)
        errs
        declarations
    in
    (declarations, leading_comments, List.rev errs)

  let let_ env =
    let env = env |> with_no_let true in
    declarations T_LET env

  let enum_declaration ?leading =
    with_loc (fun env ->
        let enum = Enum.declaration ?leading env in
        Statement.EnumDeclaration enum
    )
end
