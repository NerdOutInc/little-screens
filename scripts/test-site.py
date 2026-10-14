#!/usr/bin/env python3
"""Integration checks against a disposable LOCAL Site, never a hosted household."""
import base64,concurrent.futures,hashlib,hmac,json,sys,uuid,urllib.request,urllib.error
from pathlib import Path
from urllib.parse import urlparse
config=json.loads(Path(sys.argv[1]).read_text()); origin=config['origin']; token=config['token']
assert urlparse(origin).hostname in ('localhost','127.0.0.1'), 'Local test instances only'
image=Path(sys.argv[2]).read_bytes()

def req(path, data=None, auth=True):
    headers={'Authorization':'Bearer '+token} if auth else {}
    if data is not None:headers['Content-Type']='application/json'
    request=urllib.request.Request(origin+path,data=json.dumps(data).encode() if data is not None else None,headers=headers)
    try:
        with urllib.request.urlopen(request) as r:return r.status,{k.lower():v for k,v in r.headers.items()},r.read()
    except urllib.error.HTTPError as e:return e.code,{k.lower():v for k,v in e.headers.items()},e.read()

def api(action,body):
    code,headers,raw=req('/api/'+action,body)
    return code,json.loads(raw)

def save(name):
    body={'request_id':str(uuid.uuid4()),'expected_revision':0,'name':name,'instructions':'Test instructions','refresh_seconds':300,'active':True}
    code,res=api('save_screen',body);assert code==200,(code,res)
    assert api('save_screen',body)[1]==res
    assert api('save_screen',{**body,'name':'different'})[0]==409
    return res['id']

assert req('/api/screens',auth=False)[0]==404
assert req('/?token=wrong',auth=False)[0]==404
ids=[save('Integration test '+str(i)) for i in range(3)]
a=ids[0]
pub={'request_id':str(uuid.uuid4()),'expected_revision':1,'id':a,'png_base64':base64.b64encode(image).decode(),'metadata':{'test':True}}
assert api('publish_screen',{**pub,'request_id':str(uuid.uuid4()),'png_base64':'bad'})[0]==400
code,p=api('publish_screen',pub);assert code==200,(code,p)
assert p['revision']==2
assert api('publish_screen',pub)[1]==p
assert api('publish_screen',{**pub,'request_id':str(uuid.uuid4())})[0]==409
key=hmac.new(token.encode(),('device:'+a).encode(),hashlib.sha256).hexdigest()[:32]
base='/d/'+a+'/'+key
assert req('/d/'+a+'/wrong/api/setup',auth=False)[0]==404
code,headers,raw=req(base+'/api/setup',auth=False); setup=json.loads(raw);assert code==200 and setup['status']==200 and setup['refresh_rate']==300
code,_,raw=req(base+'/api/display',auth=False); display=json.loads(raw);assert code==200 and display['status']==0
path=urlparse(display['image_url']).path
code,headers,raw=req(path,auth=False);assert code==200 and raw==image and int(headers['content-length'])==len(image)
assert req('/d/'+ids[1]+'/'+key+'/api/setup',auth=False)[0]==404
# Same-revision competing publications: exactly one may commit.
args=[{**pub,'request_id':str(uuid.uuid4()),'expected_revision':2} for _ in range(2)]
with concurrent.futures.ThreadPoolExecutor() as pool: results=list(pool.map(lambda b:api('publish_screen',b),args))
assert sorted(r[0] for r in results)==[200,409],results
# Prior immutable URL survives a new publication.
assert req(path,auth=False)[0]==200
body={'request_id':str(uuid.uuid4()),'expected_revision':3,'id':a,'name':'Disconnected test','instructions':'Test','refresh_seconds':300,'active':False}
assert api('save_screen',body)[0]==200
assert req(base+'/api/display',auth=False)[0]==404
print('PASS: auth/404, three independent IDs, idempotency, invalid PNG, stale writes, concurrent publication, firmware JSON, Content-Length, immutable image URL, disconnect')
