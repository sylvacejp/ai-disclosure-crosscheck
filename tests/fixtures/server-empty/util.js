'use strict';
// fixture: server code with no AI provider call (signal A must NOT fire).
function add(a, b) {
  return a + b;
}

module.exports = { add };
