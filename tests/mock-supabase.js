(()=>{const K='sbmock';const ST=JSON.parse(localStorage.getItem(K)||'{"rows":[],"files":{},"acc":[],"sess":{}}');ST.acc=ST.acc||[];ST.sess=ST.sess||{};ST.sh=ST.sh||[];const save=()=>localStorage.setItem(K,JSON.stringify(ST));
const ADMIN='admin-secret',CODE='kode123';
const rnd=()=>[...crypto.getRandomValues(new Uint8Array(16))].map(x=>x.toString(16).padStart(2,'0')).join('');
const acct=t=>ST.sess[t]||null;const A=id=>ST.acc.find(a=>a.id===id);
const newSess=id=>{const t=rnd();ST.sess[t]=id;save();return t};
const can=(id,t,ad)=>{const a=acct(t);if(!a)return false;const r=ST.rows.find(x=>x.id===id);return ad===ADMIN||(r&&r.owner_id===a)};
const rpcs={
 needs_join_code:()=>true,
 is_admin:({p_admin})=>p_admin===ADMIN,
 sign_up({p_login,p_name,p_pw,p_code}){if(p_code!==CODE)return{error:'join_code'};const l=(p_login||'').trim().toLowerCase();if(!/^[a-z0-9_.-]{3,20}$/.test(l))return{error:'bad_id'};if(!p_name)return{error:'bad_name'};if((p_pw||'').length<6)return{error:'bad_pw'};if(ST.acc.some(a=>a.login===l))return{error:'id_taken'};
   const id=crypto.randomUUID();ST.acc.push({id,login:l,name:p_name,pw:p_pw,failed:0});save();return{token:newSess(id),id,login:l,name:p_name}},
 sign_in({p_login,p_pw}){const a=ST.acc.find(x=>x.login===(p_login||'').trim().toLowerCase());if(!a)return{error:'bad_login'};if(a.locked)return{error:'locked'};if(a.pw!==p_pw){a.failed++;if(a.failed>=10){a.locked=1;a.failed=0}save();return{error:'bad_login'}}a.failed=0;save();return{token:newSess(a.id),id:a.id,login:a.login,name:a.name}},
 sign_out({p_token}){delete ST.sess[p_token];save();return null},
 me({p_token}){const a=A(acct(p_token));return a?{id:a.id,login:a.login,name:a.name}:null},
 set_name({p_token,p_name}){const a=A(acct(p_token));if(!a)return{error:'auth'};a.name=p_name;save();return{name:p_name}},
 change_password({p_token,p_old,p_new}){const a=A(acct(p_token));if(!a)return{error:'auth'};if(a.pw!==p_old)return{error:'bad_login'};if((p_new||'').length<6)return{error:'bad_pw'};a.pw=p_new;for(const[k,v] of Object.entries(ST.sess))if(v===a.id&&k!==p_token)delete ST.sess[k];save();return{ok:true}},
 admin_reset_password({p_token,p_admin,p_login,p_new}){if(!acct(p_token)||p_admin!==ADMIN)return{error:'forbidden'};const a=ST.acc.find(x=>x.login===p_login);if(!a)return{error:'no_user'};a.pw=p_new;a.locked=0;for(const[k,v] of Object.entries(ST.sess))if(v===a.id)delete ST.sess[k];save();return{ok:true}},
 list_sets({p_token}){const v=acct(p_token);if(!v)return JSON.parse(JSON.stringify(ST.rows)).filter(r=>(!r.owner_id||r.visibility==='public')&&!r.deleted_at).map(r=>Object.assign(r,{author_name:(A(r.owner_id)||{}).name||null,shared_with_me:false,share_count:null}));const vis=r=>!r.owner_id||r.owner_id===v||r.visibility==='public'||(r.visibility==='partial'&&ST.sh.some(h=>h.set===r.id&&h.acc===v&&h.status==='accepted'));return JSON.parse(JSON.stringify(ST.rows)).filter(vis).map(r=>Object.assign(r,{author_name:(A(r.owner_id)||{}).name||null,shared_with_me:r.owner_id!==v&&r.visibility==='partial',share_count:r.owner_id===v?ST.sh.filter(h=>h.set===r.id).length:null})).sort((a,b)=>b.updated_at.localeCompare(a.updated_at))},
 create_set({p,p_token}){const a=acct(p_token);if(!a)throw{message:'auth'};const id=crypto.randomUUID();const now=new Date().toISOString();
   ST.rows.push({id,title:p.title||'제목 없음',script:p.script,mode:p.mode||'auto',fmt:p.fmt===2?2:1,tts:!!p.tts,segs:p.segs||null,spk:p.spk||null,pr:p.pr||null,dur:p.dur||null,name:p.name||null,audio_path:p.audio_path||null,audio_mime:p.audio_mime||null,author:A(a).name,owner_id:a,lang:p.lang||'id',visibility:p.visibility||'public',created_at:p.created_ms?new Date(p.created_ms).toISOString():now,updated_at:now,deleted_at:null});for(const u of (p.share||[]))if(u!==a&&A(u))ST.sh.push({set:id,acc:u,status:'pending'});save();return id},
 update_set({p_id,p_token,p,p_admin}){if(!can(p_id,p_token,p_admin))throw{message:'forbidden'};const r=ST.rows.find(x=>x.id===p_id);if('script' in p&&!p.script)throw{message:'bad_script'};for(const k of ['title','lang','script','mode','tts','dur','name','audio_path','audio_mime','segs','spk','pr'])if(k in p)r[k]=p[k];if('deleted' in p)r.deleted_at=p.deleted?new Date().toISOString():null;else r.updated_at=new Date().toISOString();window.__upd=(window.__upd||0)+1;save();return null},
 purge_set({p_id,p_token,p_admin}){if(!can(p_id,p_token,p_admin))throw{message:'forbidden'};ST.rows=ST.rows.filter(x=>x.id!==p_id);save();return null},
 claim_sets(){return 0},
 share_set({p_token,p_id,p_visibility,p_users}){const v=acct(p_token);const r=ST.rows.find(x=>x.id===p_id);if(!v)return{error:'auth'};if(!r||r.owner_id!==v)return{error:'forbidden'};r.visibility=p_visibility;if(p_visibility==='partial'){ST.sh=ST.sh.filter(h=>h.set!==p_id||(p_users||[]).includes(h.acc));for(const u of p_users||[])if(u!==v&&!ST.sh.some(h=>h.set===p_id&&h.acc===u))ST.sh.push({set:p_id,acc:u,status:'pending'})}save();return{ok:true}},
 get_shares({p_token,p_id}){const v=acct(p_token);const r=ST.rows.find(x=>x.id===p_id);if(!r||r.owner_id!==v)return[];return ST.sh.filter(h=>h.set===p_id).map(h=>{const a=A(h.acc);return{id:a.id,login:a.login,name:a.name,status:h.status}})},
 find_users({p_token,p_q}){const v=acct(p_token);const q=(p_q||'').trim().toLowerCase().replace(/^@/,'');if(!v||!q)return[];return ST.acc.filter(a=>a.id!==v&&(a.login.startsWith(q)||a.name.toLowerCase().includes(q))).slice(0,10).map(a=>({id:a.id,login:a.login,name:a.name}))},
 list_inbox({p_token}){const v=acct(p_token);if(!v)throw{message:'auth'};return ST.sh.filter(h=>h.acc===v&&h.status==='pending').map(h=>{const r=ST.rows.find(x=>x.id===h.set);return r&&r.visibility==='partial'&&!r.deleted_at?{set_id:r.id,title:r.title,lang:r.lang,owner_name:(A(r.owner_id)||{}).name,owner_login:(A(r.owner_id)||{}).login}:null}).filter(Boolean)},
 respond_share({p_token,p_set_id,p_accept}){const v=acct(p_token);const h=ST.sh.find(x=>x.set===p_set_id&&x.acc===v);if(!h)return{error:'no_share'};h.status=p_accept?'accepted':'declined';save();return{ok:true}}
};
window.supabase={createClient:()=>({
 async rpc(n,a){try{const fresh=JSON.parse(localStorage.getItem(K)||'null');if(fresh)Object.assign(ST,fresh);return{data:await rpcs[n](a||{}),error:null}}catch(e){return{data:null,error:e}}},
 storage:{from:()=>({async upload(path,blob,o){const r=new FileReader();const d=await new Promise(res=>{r.onload=()=>res(r.result);r.readAsDataURL(blob)});ST.files[path]={d,type:o.contentType};save();return{data:{path},error:null}},
   getPublicUrl:p=>({data:{publicUrl:'https://mock.storage/'+p}}),async remove(){return{data:null,error:{message:'denied'}}}})}
})};
const of=window.fetch;window.fetch=async(u,...a)=>{const m=String(u).match(/^https:\/\/mock\.storage\/(.+)$/);if(m){const f=ST.files[m[1]];if(!f)return new Response('',{status:404});return of(f.d)}return of(u,...a)};
})();
