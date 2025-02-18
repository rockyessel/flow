
/* @providesModule Foo */

const Bar = require('Bar');
const Qux = require('Qux');

class Foo extends Qux {
  x:string;
  constructor(x:string) {
    this.x = x;
  }

  foo(y:string,z:string):number {
    this.x = y;
    var u = new Foo("...").qux();
    var v = new Bar(y);
    v.self = v;
    return v.bar(z,u);
  }

  fooqux(x:string) {
    this.x;
  }
}

module.exports = Foo;
