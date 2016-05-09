module Anno = Type_annotation
module Ast = Spider_monkey_ast
module Flow = Flow_js
module Utils = Utils_js

open Reason_js

type field = Type.t * Ast.Expression.t option

type method_kind = Method | Getter | Setter

type signature = {
  reason: reason;
  super: Type.t;
  fields: field SMap.t;
  (* Multiple function signatures indicates an overloaded method. Note that
     function signatures are stored in reverse definition order. *)
  methods: Func_sig.t list SMap.t;
  getters: Func_sig.t SMap.t;
  setters: Func_sig.t SMap.t;
  (* Track the order of method declarations, so they can be processed in the
     same order. The order shouldn't necessarily matter, but does currently at
     least due to a bug (facebook/flow/issues#1745). Note that this list is in
     reverse order. *)
  method_decls: (method_kind * string) list;
}

type t = {
  id: int;
  structural: bool;
  tparams: Type.typeparam list;
  tparams_map: Type.t SMap.t;
  (* Multiple function signatures indicates an overloaded constructor. Note that
     function signatures are stored in reverse definition order. *)
  constructor: Func_sig.t list;
  static: signature;
  instance: signature;
}

let empty ?(structural=false) id reason tparams tparams_map super =
  let empty_sig reason super = {
    reason; super;
    fields = SMap.empty;
    methods = SMap.empty;
    getters = SMap.empty;
    setters = SMap.empty;
    method_decls = [];
  } in
  let constructor = [] in
  let static =
    let super = Type.ClassT super in
    let reason = prefix_reason "statics of " reason in
    empty_sig reason super
  in
  let instance = empty_sig reason super in
  { id; structural; tparams; tparams_map; constructor; static; instance }

let map_sig ~static f s =
  if static
  then {s with static = f s.static}
  else {s with instance = f s.instance}

let with_sig ~static f s =
  if static then f s.static else f s.instance

let mutually f = (f ~static:true, f ~static:false)

let add_field name fld = map_sig (fun s -> {
  s with
  fields = SMap.add name fld s.fields;
  getters = SMap.remove name s.getters;
  setters = SMap.remove name s.setters;
})

let add_constructor fsig s =
  {s with constructor = [fsig]}

let add_default_constructor reason s =
  let fsig = Func_sig.default_constructor s.tparams_map reason in
  add_constructor fsig s

let append_constructor fsig s =
  {s with constructor = fsig::s.constructor}

(* Adding a method *overwrites* any existing methods. This implements the
   behavior of classes, which permit duplicate definitions where latter
   definitions overwrite former ones. *)
let add_method name fsig = map_sig (fun s -> {
  s with
  methods = SMap.add name [fsig] s.methods;
  getters = SMap.remove name s.getters;
  setters = SMap.remove name s.setters;
  method_decls = (Method, name)::s.method_decls;
})

(* Appending a method builds a list of function signatures. This implements the
   bahvior of interfaces and declared classes, which interpret duplicate
   definitions as branches of a single overloaded method. *)
let append_method name fsig = map_sig (fun s ->
  let methods = match SMap.get name s.methods with
  | Some fsigs -> SMap.add name (fsig::fsigs) s.methods
  | None -> SMap.add name [fsig] s.methods
  in
  let method_decls = (Method, name)::s.method_decls in
  {s with methods; method_decls}
)

let add_getter name fsig = map_sig (fun s -> {
  s with
  getters = SMap.add name fsig s.getters;
  methods = SMap.remove name s.methods;
  method_decls = (Getter, name)::s.method_decls;
})

let add_setter name fsig = map_sig (fun s -> {
  s with
  setters = SMap.add name fsig s.setters;
  methods = SMap.remove name s.methods;
  method_decls = (Setter, name)::s.method_decls;
})

let mk_method cx x reason func =
  Func_sig.mk cx x.tparams_map reason func

let mk_field cx x reason typeAnnotation value =
  let t = Anno.mk_type_annotation cx x.tparams_map reason typeAnnotation in
  (t, value)

let mem_constructor {constructor; _} = constructor <> []

(* visits all methods, getters, and setters in declaration order *)
let iter_methods f {methods; getters; setters; method_decls; _} =
  let rec loop methods = function
    | [] -> ()
    | (kind, name)::decls ->
      let x, methods = match kind with
      | Method ->
        let m = SMap.find_unsafe name methods in
        let methods = SMap.add name (List.tl m) methods in
        List.hd m, methods
      | Getter ->
        SMap.find_unsafe name getters, methods
      | Setter ->
        SMap.find_unsafe name setters, methods
      in
      f x; loop methods decls
  in
  let methods = SMap.map List.rev methods in
  let method_decls = List.rev method_decls in
  loop methods method_decls

let subst_field cx map (t, value) =
  Flow.subst cx map t, value

let subst_sig cx map s = {
  reason = s.reason;
  super = Flow.subst cx map s.super;
  fields = SMap.map (subst_field cx map) s.fields;
  methods = SMap.map (List.map (Func_sig.subst cx map)) s.methods;
  getters = SMap.map (Func_sig.subst cx map) s.getters;
  setters = SMap.map (Func_sig.subst cx map) s.setters;
  method_decls = s.method_decls;
}

let generate_tests cx f x =
  let {tparams_map; constructor; static; instance; _} = x in
  Flow.generate_tests cx x.instance.reason x.tparams (fun map -> f {
    x with
    tparams_map = SMap.map (Flow.subst cx map) tparams_map;
    constructor = List.map (Func_sig.subst cx map) constructor;
    static = subst_sig cx map static;
    instance = subst_sig cx map instance;
  })

let elements cx ?constructor = with_sig (fun s ->
  let methods =
    (* If this is an overloaded method, create an intersection, attributed
       to the first declared function signature. If there is a single
       function signature for this method, simply return the method type. *)
    SMap.map Type.(fun xs ->
      match List.rev_map Func_sig.methodtype xs with
      | [] -> EmptyT.t
      | [t] -> t
      | t::_ as ts -> IntersectionT (reason_of_t t, InterRep.make ts)
    ) s.methods
  in

  (* Re-add the constructor as a method. *)
  let methods = match constructor with
  | Some t -> SMap.add "constructor" t methods
  | None -> methods
  in

  (* If there is a both a getter and a setter, then flow the setter type to
     the getter. Otherwise just use the getter type or the setter type *)
  let getters = SMap.map Func_sig.gettertype s.getters in
  let setters = SMap.map Func_sig.settertype s.setters in
  let getters_and_setters = SMap.fold (fun name t ts ->
    match SMap.get name ts with
    | Some t' -> Flow.unify cx t t'; ts
    | None -> SMap.add name t ts
  ) setters getters in

  (* Treat getters and setters as fields *)
  let fields = SMap.map fst s.fields in
  let fields = SMap.union getters_and_setters fields in

  fields, methods
)

let arg_polarities x =
  List.fold_left Type.(fun acc tp ->
    SMap.add tp.name tp.polarity acc
  ) SMap.empty x.tparams

let insttype ~static cx s =
  let class_id = if static then 0 else s.id in
  let constructor = if static then None else
    let ts = List.rev_map Func_sig.methodtype s.constructor in
    match ts with
    | [] -> None
    | [t] -> Some t
    | t::_ as ts ->
      let open Type in
      let t = IntersectionT (reason_of_t t, InterRep.make ts) in
      Some t
  in
  let fields, methods = elements ?constructor ~static cx s in
  { Type.
    class_id;
    type_args = s.tparams_map;
    arg_polarities = arg_polarities s;
    fields_tmap = Flow.mk_propmap cx fields;
    methods_tmap = Flow.mk_propmap cx methods;
    mixins = false;
    structural = s.structural;
  }

and remove_this x =
  if x.structural then x else {
    x with
    tparams = List.rev (List.tl (List.rev x.tparams));
    tparams_map = SMap.remove "this" x.tparams_map;
  }

let check_super ~static cx x =
  let x = remove_this x in
  let reason = x.instance.reason in
  let super = with_sig ~static (fun s -> s.super) x in
  let insttype = insttype ~static cx x in
  Flow.flow cx (super, Type.SuperT (reason, insttype))

(* TODO: Ideally we should check polarity for all class types, but this flag is
   flipped off for interface/declare class currently. *)
let classtype ?(check_polarity=true) cx x =
  let x = remove_this x in
  let {
    structural;
    tparams;
    static = {reason = sreason; super = ssuper; _};
    instance = {reason; super; _};
    _;
  } = x in
  let open Type in
  let sinsttype, insttype = mutually (insttype cx x) in
  let static = InstanceT (sreason, MixedT.t, ssuper, sinsttype) in
  let this = InstanceT (reason, static, super, insttype) in
  (if check_polarity then Flow.check_polarity cx Positive this);
  let t = if structural then ClassT this else ThisClassT this in
  if tparams = [] then t else PolyT (tparams, t)

(* Processes the bodies of instance and static class members. *)
let toplevels cx ~decls ~stmts ~expr x =
  let new_entry t = Scope.Entry.new_var ~loc:(Type.loc_of_t t) t in

  let method_ this super f =
    let save_return = Abnormal.clear_saved Abnormal.Return in
    let save_throw = Abnormal.clear_saved Abnormal.Throw in
    f |> Func_sig.generate_tests cx (
      Func_sig.toplevels None cx this super ~decls ~stmts ~expr
    );
    ignore (Abnormal.swap_saved Abnormal.Return save_return);
    ignore (Abnormal.swap_saved Abnormal.Throw save_throw)
  in

  let field config this super name (field_t, value) =
    match config, value with
    | Options.ESPROPOSAL_IGNORE, _ -> ()
    | _, None -> ()
    | _, Some ((loc, _) as expr) ->
      let init =
        let desc = Utils.spf "field initializer for `%s`" name in
        let reason = mk_reason desc loc in
        Func_sig.field_initializer x.tparams_map reason expr field_t
      in
      method_ this super init
  in

  let this = SMap.find_unsafe "this" x.tparams_map in
  let static = Type.ClassT this in

  x |> with_sig ~static:true (fun s ->
    (* process static methods and fields *)
    let this, super = new_entry static, new_entry s.super in
    iter_methods (method_ this super) s;
    let config = Context.esproposal_class_static_fields cx in
    SMap.iter (field config this super) s.fields
  );

  x |> with_sig ~static:false (fun s ->
    (* process constructor *)
    begin
      (* When in a derived constructor, initialize this and super to undefined.
         For internal names, we can afford to initialize with undefined and
         fatten the declared type to allow undefined. This works because we
         always look up the flow-sensitive type of internals, and don't havoc
         them. However, the same trick wouldn't work for normal uninitialized
         locals, e.g., so it cannot be used in general to track definite
         assignments. *)
      let derived_ctor = Type.(match s.super with
        | ClassT (MixedT _) -> false
        | MixedT _ -> false
        | _ -> true
      ) in
      let new_entry t =
        if derived_ctor then
          let open Type in
          let specific =
            let msg = "uninitialized this (expected super constructor call)" in
            VoidT (replace_reason msg (reason_of_t this))
          in
          Scope.Entry.new_var ~loc:(loc_of_t t) ~specific (OptionalT t)
        else
          new_entry t
      in
      let this, super = new_entry this, new_entry s.super in
      x.constructor |> List.iter (method_ this super)
    end;

    (* process instance methods and fields *)
    begin
      let this, super = new_entry this, new_entry s.super in
      iter_methods (method_ this super) s;
      let config = Context.esproposal_class_instance_fields cx in
      SMap.iter (field config this super) s.fields
    end
  )
