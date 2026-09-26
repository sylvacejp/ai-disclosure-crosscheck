'use strict';
// fixture: a real (non-excluded) Anthropic call, sitting alongside the
// vendor/ one so the exclusion test can confirm this one is still found.
const Anthropic = require('@anthropic-ai/sdk');
module.exports = new Anthropic({ apiKey: 'x' });
