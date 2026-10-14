#!/usr/bin/env node
// Copy reusable Site source into a private deployment checkout. No credentials.
import { cp, mkdir, readFile, writeFile, readdir, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const get = name => { const i = args.indexOf(name); if (i < 0 || !args[i+1]) throw new Error('Required: ' + name); return args[i+1]; };
const projectId = get('--project-id'), destination = path.resolve(get('--destination'));
if (!/^appgprj_[a-zA-Z0-9]+$/.test(projectId)) throw new Error('Use the exact Site ID returned by Sites');
const source = path.join(root, 'site');
if (destination === root || destination === source || destination.startsWith(source + path.sep) || source.startsWith(destination + path.sep)) throw new Error('Choose a separate private publishing directory outside the Site source');
await mkdir(destination, {recursive: true});
try { const previous = JSON.parse(await readFile(path.join(destination, '.openai/hosting.json'), 'utf8')); if (previous.project_id !== projectId) throw new Error('Destination belongs to another Site'); } catch(e) { if (e.code !== 'ENOENT') throw e; }
const skip = new Set(['node_modules', 'dist', '.wrangler', '.sites-runtime', '.git', '.next', '.vinext']);
const allowed = name => !skip.has(name) && !name.startsWith('.env') && !name.startsWith('.dev.vars') && !name.endsWith('.tsbuildinfo') && name !== 'hosting.json';
async function copy(from, to) { await mkdir(to, {recursive:true}); for (const name of await readdir(from)) { if (!allowed(name)) continue; const sourcePath=path.join(from,name), target=path.join(to,name); if ((await stat(sourcePath)).isDirectory()) await copy(sourcePath,target); else await cp(sourcePath,target); } }
await copy(source, destination);
const hosting = JSON.parse(await readFile(path.join(source, '.openai/hosting.example.json'), 'utf8'));
await mkdir(path.join(destination,'.openai'),{recursive:true});
await writeFile(path.join(destination,'.openai/hosting.json'), JSON.stringify({...hosting,project_id:projectId},null,2)+'\n');
const ignorePath=path.join(destination,'.gitignore');
const ignore=(await readFile(ignorePath,'utf8')).replace(/^\/\.openai\/hosting\.json\s*$/gm,'');
await writeFile(ignorePath,ignore+'\n!/.openai/hosting.json\n');
console.log(JSON.stringify({project_id:projectId,checkout_path:destination}));
