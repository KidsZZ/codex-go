#!/usr/bin/env node
// Agent 和用户共用一个发布入口；正式版只能来自已经公开的 Beta 提交。
import {execFileSync} from 'node:child_process';
import {readFileSync, appendFileSync} from 'node:fs';
const repo = 'KidsZZ/codex-go';
const args = process.argv.slice(2);
function run(command, values) { return execFileSync(command, values, {encoding:'utf8', stdio:['ignore','pipe','pipe']}).trim(); }
function api(endpoint, extra=[]) { return JSON.parse(run('gh',['api',`repos/${repo}/${endpoint}`, ...extra])); }
function option(name) { const i=args.indexOf(name); return i<0 ? '' : (args[i+1] ?? ''); }
function sourceVersion(text) {
  const match=/^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$/m.exec(text);
  if (!match) throw Error('pubspec.yaml 必须使用稳定基础版本和递增构建号，例如 0.1.2+3。');
  const base=Number(match[2]);
  if (!Number.isSafeInteger(base) || base<1 || base>2000000) throw Error('基础构建号超出范围。');
  return {version:match[1],base};
}
function absentTag(tag) {
  const refs=api(`git/matching-refs/tags/${tag}`);
  if(refs.some(r=>r.ref===`refs/tags/${tag}`)) throw Error(`标签 ${tag} 已存在，不允许覆盖；请检查已发布版本或提升基础版本。`);
}
function emit(values) {
  if(!process.env.GITHUB_OUTPUT) throw Error('prepare 只能在 Actions 中运行。');
  for(const [key,value] of Object.entries(values)) appendFileSync(process.env.GITHUB_OUTPUT,`${key}=${value}\n`);
  console.log(`准备 ${values.tag}，源码 ${values.source_sha}，构建号 ${values.build_number}`);
}
try {
  const mode=args[0];
  if(mode==='prepare') {
    const channel=process.env.RELEASE_CHANNEL;
    if(!['beta','release'].includes(channel)) throw Error('无效发布渠道。');
    if(process.env.GITHUB_REF!=='refs/heads/main') throw Error('请从 main 分支运行发布工作流。');
    let source=run('git',['rev-parse','HEAD']);
    let text=readFileSync('pubspec.yaml','utf8');
    let sourceBeta='';
    let betaNumber=0;
    if(channel==='release') {
      sourceBeta=process.env.SOURCE_BETA ?? '';
      if(!/^v\d+\.\d+\.\d+-beta\.[1-9]\d*$/.test(sourceBeta)) throw Error('正式发行必须填写已验收的 Beta 标签。');
      const release=api(`releases/tags/${sourceBeta}`);
      if(release.draft || !release.prerelease) throw Error('来源必须是已公开的 Beta 预发布。');
      source=api(`commits/${sourceBeta}`).sha;
      const asset=release.assets.find(a=>a.name==='update.json' && a.state==='uploaded');
      if(!asset) throw Error('Beta 缺少更新元数据。');
      const metadata=api(`releases/assets/${asset.id}`,['-H','Accept: application/octet-stream']);
      if(metadata.channel!=='beta' || metadata.sourceCommit!==source || `v${metadata.versionName}`!==sourceBeta) throw Error('Beta 元数据与源码提交不一致。');
      const content=api(`contents/pubspec.yaml?ref=${source}`);
      text=Buffer.from(content.content,'base64').toString('utf8');
    }
    const {version,base}=sourceVersion(text);
    absentTag(`v${version}`);
    if(channel==='beta') {
      const refs=api(`git/matching-refs/tags/v${version}-beta.`);
      const numbers=refs.map(r=>Number(r.ref.split('-beta.')[1])).filter(Number.isSafeInteger);
      betaNumber=Math.max(0,...numbers)+1;
      if(betaNumber>=999) throw Error('本版本 Beta 次数已满，请提升基础版本。');
    } else if(!sourceBeta.startsWith(`v${version}-beta.`)) throw Error('Beta 与源码基础版本不匹配。');
    const name=channel==='beta' ? `${version}-beta.${betaNumber}` : version;
    absentTag(`v${name}`);
    emit({channel,tag:`v${name}`,version:name,build_number:base*1000+(channel==='beta'?betaNumber:999),source_sha:source,source_beta:sourceBeta});
  } else if(mode==='beta' || mode==='release') {
    // 本地入口只触发工作流，不偷偷提交未审阅文件。
    if(run('git',['status','--porcelain'])) throw Error('请先提交本次修改，保持工作区干净后再发布。');
    const head=run('git',['rev-parse','HEAD']);
    if(api('commits/main').sha!==head) throw Error('请先将本次提交推送到 main。');
    const dispatch=['workflow','run','release.yml','--repo',repo,'--ref','main','-f',`channel=${mode}`];
    if(mode==='release') {
      const beta=option('--beta');
      if(!/^v\d+\.\d+\.\d+-beta\.[1-9]\d*$/.test(beta)) throw Error('用法：node tool/release.mjs release --beta v0.1.2-beta.1 [--publish]');
      dispatch.push('-f',`source_beta=${beta}`,'-f',`publish=${args.includes('--publish')}`);
    }
    console.log(run('gh',dispatch));
    console.log(mode==='beta'?'Beta 发布已启动。':'正式版构建已启动；未指定 --publish 时生成草稿。');
  } else throw Error('用法：node tool/release.mjs beta | release --beta <已验收标签> [--publish]');
} catch(error) {
  console.error(error.message);
  if(error.stderr) console.error(error.stderr.toString().slice(0,1500));
  process.exitCode=1;
}
