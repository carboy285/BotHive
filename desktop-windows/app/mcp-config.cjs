const fs=require('node:fs/promises');const path=require('node:path');const {randomUUID}=require('node:crypto');
const {trustedURL,variable}=require('./composio.cjs');
const {SERVER_NAME:TOOLS_SERVER,TOKEN_VARIABLE:TOOLS_TOKEN}=require('./tools-server.cjs');
/** `tools` (10.2) is Bothive's own local tool server for this run: {url, token}. Only Claude Code takes it for now. */
async function configure(provider,directory,url,tools=null){
  const withTools=!!(tools&&provider==='claude'&&/^http:\/\/127\.0\.0\.1:\d+\/mcp$/.test(tools.url)&&tools.token);
  if(!url&&!withTools)return {arguments:[],environment:{},cleanup:async()=>{}};
  if(url&&!trustedURL(url))throw new Error('Set up Composio again.');
  const helper=path.join(__dirname.replace('app.asar'+path.sep,'app.asar.unpacked'+path.sep),'composio-bridge.cjs'),name='opengrokbot-composio',command=process.execPath,args=[helper];
  const environment=url?{[variable]:url}:{};const result={arguments:[],environment};const files=[];
  result.cleanup=async()=>{for(const file of files)await fs.rm(file,{force:true}).catch(()=>{});};
  const write=async(relative,body)=>{const file=path.join(directory,relative);await fs.mkdir(path.dirname(file),{recursive:true,mode:0o700});try{await fs.writeFile(file,body,{flag:'wx',mode:0o600});}catch(error){if(error.code!=='EEXIST'||await fs.readFile(file,'utf8')!==body)throw error;}files.push(file);return file;};
  const server={command,args,env:{[variable]:'${'+variable+'}',ELECTRON_RUN_AS_NODE:'1'}};
  try{
    if(provider==='codex')result.arguments=['-c',`mcp_servers.${name}.command=${JSON.stringify(command)}`,'-c',`mcp_servers.${name}.args=${JSON.stringify(args)}`,'-c',`mcp_servers.${name}.env_vars=["${variable}"]`,'-c',`mcp_servers.${name}.env.ELECTRON_RUN_AS_NODE="1"`];
    else if(provider==='claude'){
      // The token travels in the environment; the file only names the variable, so nothing secret is written to disk.
      const servers={};if(url)servers[name]=server;
      if(withTools){servers[TOOLS_SERVER]={type:'http',url:tools.url,headers:{Authorization:'Bearer ${'+TOOLS_TOKEN+'}'}};environment[TOOLS_TOKEN]=tools.token;environment.MCP_TOOL_TIMEOUT=environment.MCP_TOOL_TIMEOUT||'600000';}
      result.arguments=['--mcp-config',await write('.composio-'+randomUUID()+'.json',JSON.stringify({mcpServers:servers}))];
    }
    else if(provider==='grok')await write('.grok/config.toml',`[mcp_servers.${name}]\ncommand = ${JSON.stringify(command)}\nargs = ${JSON.stringify(args)}\n[mcp_servers.${name}.env]\n${variable} = "\u0024{${variable}}"\nELECTRON_RUN_AS_NODE = "1"\n`);
    else if(provider==='opencode')environment.OPENCODE_CONFIG=await write('.composio-'+randomUUID()+'.json',JSON.stringify({mcp:{[name]:{type:'local',command:[command,...args],enabled:true,environment:{[variable]:'{env:'+variable+'}',ELECTRON_RUN_AS_NODE:'1'}}}}));
    else if(provider==='gemini')await write('.gemini/settings.json',JSON.stringify({mcpServers:{[name]:server}}));
    return result;
  }catch(error){await result.cleanup();throw error;}
}
module.exports={configure,TOOLS_SERVER};
