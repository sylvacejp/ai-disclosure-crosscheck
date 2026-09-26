'use strict';
// fixture: a server-side OpenAI SDK call (signal A should fire, provider=OpenAI)
const OpenAI = require('openai');

async function ask(prompt) {
  const client = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
  return client.chat.completions.create({
    model: 'gpt-4o',
    messages: [{ role: 'user', content: prompt }],
  });
}

module.exports = { ask };
