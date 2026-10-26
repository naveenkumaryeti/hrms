async function api(u,m,b){const r=await fetch(u,{method:m||'GET',headers:{'Content-Type':'application/json'},body:b?JSON.stringify(b):undefined});let d={};try{d=await r.json()}catch(e){}d.status=r.status;return d}
function show(id,ok,t){const e=document.getElementById(id);e.className='msg '+(ok?'ok':'err');e.textContent=t}
async function guard(role){const d=await api('/api/auth/me');if(d.status!==200||(role&&d.role!==role))location.href='/';return d}
async function logout(){await api('/api/auth/logout','POST');location.href='/'}
