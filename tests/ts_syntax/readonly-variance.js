type Obj = {
  readonly foo: string, // ERROR
};
type Valid = {
  readonly: string, // OK
  readonly?: string, // OK
  readonly<T>(number): string, // OK
};

type Tuple = [readonly foo: 1]; // ERROR
type ValidTuple = [readonly: 1]; // OK

type Indexer = {
  readonly [string]: mixed; // ERROR
};

class C {
  readonly prop: string; // ERROR
}

interface I {
  readonly prop: string; // ERROR
}
