'use strict';
// fixture: an OpenAI call that lives under vendor/, meant to be excluded via
// a bare path-glob entry in .precheck-ignore ("vendor").
const OpenAI = require('openai');
module.exports = new OpenAI({ apiKey: 'x' });
