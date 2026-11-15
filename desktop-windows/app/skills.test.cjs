'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const skills = require('./skills.cjs');

const SKILL = `---
name: pdf-forms
description: Fill in and check PDF forms
---
# PDF forms

Always list the fields first.
`;

test('reads a SKILL.md: front matter, quotes and folded blocks', () => {
  const one = skills.parseSkillMarkdown(SKILL);
  assert.deepEqual(one, { name: 'pdf-forms', description: 'Fill in and check PDF forms', text: '# PDF forms\n\nAlways list the fields first.' });
  const folded = skills.parseSkillMarkdown('---\r\nname: "Quoted: name"\r\ndescription: >\r\n  one line\r\n  second line\r\n---\r\nBody here');
  assert.equal(folded.name, 'Quoted: name'); assert.equal(folded.description, 'one line second line'); assert.equal(folded.text, 'Body here');
});

test('falls back to the heading, then the folder name, and rejects empty or oversized files', () => {
  assert.equal(skills.parseSkillMarkdown('# My heading\n\nDo the thing.').name, 'My heading');
  assert.equal(skills.parseSkillMarkdown('Just text with no heading.', 'folder-name').name, 'folder-name');
  assert.throws(() => skills.parseSkillMarkdown('Just text with no heading.'), /name/);
  assert.throws(() => skills.parseSkillMarkdown('   '), /empty/);
  assert.throws(() => skills.parseSkillMarkdown('---\nname: x\n---\n'), /no instructions/);
  assert.throws(() => skills.parseSkillMarkdown('x'.repeat(skills.MAX_TEXT + 1)), /longer than/);
});

test('make builds a valid skill and refuses bad input', () => {
  const skill = skills.make({ name: '  Plan my\nweek ', description: 'd', text: '---\nstarts with dashes\n' });
  assert.equal(skill.name, 'Plan my week'); assert.equal(skill.text, '---\nstarts with dashes'); assert.ok(skills.valid(skill));
  assert.throws(() => skills.make({ name: '', text: 'x' }), /name/);
  assert.throws(() => skills.make({ name: 'x', text: '  ' }), /instructions/);
  assert.equal(skills.loadStore({ skills: [skill, { id: 'bad' }, null] }).skills.length, 1);
});

test('a Bot reads only the skills turned on for it, with the safety framing and size limits', () => {
  const a = skills.make({ name: 'A', text: 'Use bullet points.' }), b = skills.make({ name: 'B', text: 'Never use bullet points.' });
  assert.equal(skills.promptNote({ skills: [] }, [a, b]), '');
  assert.equal(skills.promptNote({}, [a, b]), '');
  const note = skills.promptNote({ skills: [a.id] }, [a, b]);
  assert.match(note, /### Skill: A/); assert.doesNotMatch(note, /Skill: B/);
  assert.match(note, /never approve anything/);
  const long = skills.make({ name: 'L', text: 'x'.repeat(skills.MAX_TEXT) });
  const cut = skills.promptNote({ skills: [long.id] }, [long]);
  assert.ok(cut.length < skills.MAX_PER_PROMPT + 800); assert.match(cut, /cut: too long/);
  const many = Array.from({ length: 6 }, (_, i) => skills.make({ name: 'S' + i, text: 'y'.repeat(8000) }));
  const total = skills.promptNote({ skills: many.map(x => x.id) }, many);
  assert.ok(total.length < skills.MAX_PROMPT_TOTAL + 1500); assert.match(total, /did not fit/);
});

test('reads GitHub, skills.sh and npx addresses', () => {
  const same = { owner: 'acme', repo: 'agent-skills', ref: null, path: null, skill: null };
  assert.deepEqual(skills.parseSource('acme/agent-skills'), same);
  assert.deepEqual(skills.parseSource('https://github.com/acme/agent-skills'), same);
  assert.deepEqual(skills.parseSource('https://github.com/acme/agent-skills.git'), same);
  assert.deepEqual(skills.parseSource('acme/agent-skills/pdf'), { ...same, skill: 'pdf' });
  assert.deepEqual(skills.parseSource('https://skills.sh/acme/agent-skills/pdf'), { ...same, skill: 'pdf' });
  assert.deepEqual(skills.parseSource('https://www.skills.sh/acme/agent-skills'), same);
  assert.deepEqual(skills.parseSource('npx skills add acme/agent-skills --skill pdf'), { ...same, skill: 'pdf' });
  assert.deepEqual(skills.parseSource('npx skills@latest add https://github.com/acme/agent-skills -s pdf'), { ...same, skill: 'pdf' });
  assert.deepEqual(skills.parseSource('https://github.com/acme/agent-skills/tree/main/skills/pdf'), { ...same, ref: 'main', path: 'skills/pdf' });
  assert.deepEqual(skills.parseSource('https://github.com/acme/agent-skills/blob/v2/skills/pdf/SKILL.md'), { ...same, ref: 'v2', path: 'skills/pdf/SKILL.md' });
  assert.deepEqual(skills.parseSource('https://raw.githubusercontent.com/acme/agent-skills/main/skills/pdf/SKILL.md'), { ...same, ref: 'main', path: 'skills/pdf/SKILL.md' });
});

test('a /../ in a web address is collapsed by the URL parser, so it can only ever mean the repository itself', () => {
  assert.deepEqual(skills.parseSource('https://github.com/acme/x/tree/main/../..'), { owner: 'acme', repo: 'x', ref: null, path: null, skill: null });
});

test('refuses other hosts, odd names and path tricks', () => {
  for (const bad of ['', 'https://evil.example/acme/x', 'http://github.com/acme/x', 'https://user:pw@github.com/acme/x', 'acme', 'a b/c', 'acme/x/../y/z', 'file:///etc/passwd', 'x'.repeat(700)])
    assert.throws(() => skills.parseSource(bad), undefined, bad);
});

function repo(files) {
  const calls = [];
  const fetchImpl = async url => {
    calls.push(url);
    if (url.startsWith('https://api.github.com/repos/acme/agent-skills/git/trees/')) return new Response(JSON.stringify({ tree: files.map(path => ({ path, type: 'blob' })).concat([{ path: 'skills', type: 'tree' }]) }));
    const raw = /^https:\/\/raw\.githubusercontent\.com\/acme\/agent-skills\/([^/]+)\/(.+)$/.exec(url);
    if (raw && raw[2] === 'skills/pdf/SKILL.md') return new Response(SKILL);
    return new Response('no', { status: 404 });
  };
  return { fetchImpl, calls };
}

test('finds SKILL.md files in one request and filters by skill or folder', async () => {
  const { fetchImpl, calls } = repo(['README.md', 'skills/pdf/SKILL.md', 'skills/pdf/scripts/run.py', 'skills/docx/SKILL.md', 'node_modules/x/SKILL.md', 'deep/a/b/c/d/e/f/g/SKILL.md']);
  const all = await skills.find('acme/agent-skills', fetchImpl);
  assert.deepEqual(all.items.map(x => x.path), ['skills/docx/SKILL.md', 'skills/pdf/SKILL.md']);
  assert.equal(calls.length, 1); assert.match(calls[0], /git\/trees\/HEAD\?recursive=1$/);
  assert.deepEqual((await skills.find('https://skills.sh/acme/agent-skills/pdf', fetchImpl)).items.map(x => x.path), ['skills/pdf/SKILL.md']);
  assert.deepEqual((await skills.find('https://github.com/acme/agent-skills/tree/main/skills/docx', fetchImpl)).items.map(x => x.path), ['skills/docx/SKILL.md']);
  await assert.rejects(skills.find('acme/agent-skills/nothing-like-this', fetchImpl), /No SKILL\.md/);
  const direct = await skills.find('https://github.com/acme/agent-skills/blob/main/skills/pdf/SKILL.md', fetchImpl);
  assert.equal(direct.items.length, 1); assert.equal(direct.ref, 'main');
});

test('fetches one skill and says what went wrong otherwise', async () => {
  const { fetchImpl } = repo(['skills/pdf/SKILL.md']);
  const got = await skills.fetchSkill({ owner: 'acme', repo: 'agent-skills', ref: 'main', path: 'skills/pdf/SKILL.md' }, fetchImpl);
  assert.equal(got.name, 'pdf-forms'); assert.equal(got.source, 'github:acme/agent-skills/skills/pdf/SKILL.md');
  await assert.rejects(skills.fetchSkill({ owner: 'acme', repo: 'agent-skills', ref: 'main', path: 'skills/none/SKILL.md' }, fetchImpl), /could not find/);
  await assert.rejects(skills.fetchSkill({ owner: 'acme', repo: 'agent-skills', ref: 'main', path: '../SKILL.md' }, fetchImpl), /could not be fetched/);
  await assert.rejects(skills.fetchSkill({ owner: 'acme', repo: 'agent-skills', ref: 'main', path: 'notes.txt' }, fetchImpl), /could not be fetched/);
  const limited = async () => new Response('', { status: 403 });
  await assert.rejects(skills.find('acme/agent-skills', limited), /limiting requests/);
  const huge = async () => new Response('x'.repeat(200000));
  await assert.rejects(skills.fetchSkill({ owner: 'acme', repo: 'agent-skills', ref: 'main', path: 'a/SKILL.md' }, huge), /too large/);
  const offline = async () => { throw new Error('down'); };
  await assert.rejects(skills.find('acme/agent-skills', offline), /could not be reached/);
});
