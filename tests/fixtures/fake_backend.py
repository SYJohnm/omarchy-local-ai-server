# Stand-in for llama-server in the slot_kv.py tests: /health (503 for DELAY
# seconds after start), and a POST answering {"model": NAME} either at once or
# as an SSE stream lasting "secs". With SLOT_DIR set it also mimics slot
# save/restore: every generation adds 100 tokens to slot 0, slot 1 stays empty.
import json, os, sys, time, threading
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
NAME=os.environ["NAME"]; ADDR=sys.argv[1]; DELAY=float(os.environ.get("DELAY","0"))
t0=time.time()
SLOT_DIR=os.environ.get("SLOT_DIR","")
TOKENS={0:0,1:0}
class H(BaseHTTPRequestHandler):
    protocol_version="HTTP/1.1"
    def log_message(self,*a): pass
    def j(self,code,obj):
        b=json.dumps(obj).encode(); self.send_response(code)
        self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if time.time()-t0<DELAY: return self.j(503,{"error":"loading"})
        if self.path=="/slots": return self.j(200,[{"id":i,"is_processing":False} for i in TOKENS])
        self.j(200,{"status":"ok","name":NAME})
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers.get("Content-Length",0))) or b"{}")
        if self.path.startswith("/slots/"):
            sid=int(self.path.split("/")[2].split("?")[0]); path=os.path.join(SLOT_DIR,body["filename"])
            if "action=save" in self.path:
                open(path,"w").write(json.dumps({"model":NAME,"tokens":TOKENS[sid]}))
                return self.j(200,{"id_slot":sid,"n_saved":TOKENS[sid]})
            data=json.load(open(path))
            if data["model"]!=NAME: return self.j(400,{"error":"model mismatch"})
            TOKENS[sid]=data["tokens"]
            return self.j(200,{"id_slot":sid,"n_restored":TOKENS[sid]})
        TOKENS[0]+=100
        secs=body.get("secs",0)
        if body.get("stream"):
            self.send_response(200); self.send_header("Content-Type","text/event-stream"); self.send_header("Transfer-Encoding","chunked"); self.end_headers()
            for i in range(int(secs*4)+1):
                d=("data: %s\n\n"%json.dumps({"model":NAME,"i":i})).encode()
                self.wfile.write(b"%x\r\n"%len(d)+d+b"\r\n"); self.wfile.flush(); time.sleep(0.25)
            d=b"data: [DONE]\n\n"; self.wfile.write(b"%x\r\n"%len(d)+d+b"\r\n0\r\n\r\n")
        else:
            time.sleep(secs); self.j(200,{"model":NAME,"len":len(body.get("pad",""))})
print(NAME,"up on",ADDR,flush=True)
if ADDR.endswith(".sock"):
    import socketserver
    class UnixHTTP(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
        daemon_threads = True
    class UH(H):
        # BaseHTTPRequestHandler expects (host, port) for logging.
        def address_string(self): return "unix"
    srv = UnixHTTP(ADDR, UH)
    srv.server_name, srv.server_port = "unix", 0
    srv.serve_forever()
else:
    ThreadingHTTPServer(("127.0.0.1",int(ADDR)),H).serve_forever()
