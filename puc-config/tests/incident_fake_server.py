import argparse
import json
from email.parser import BytesParser
from email.policy import default
from http.server import BaseHTTPRequestHandler, HTTPServer


levels = [
    {
        "level_code": "00",
        "level_name": "existing-conflict",
        "level_desc": "existing",
        "icon_color": "#000000",
        "icon_zip_name": "existing.zip",
        "toneInfo": {"file_name": "CriticalAlarm.wav"},
    }
]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send_json(self, value):
        data = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        content_type = self.headers.get("Content-Type", "")
        if content_type.startswith("multipart/form-data"):
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)
            message = BytesParser(policy=default).parsebytes(
                ("Content-Type: " + content_type + "\r\nMIME-Version: 1.0\r\n\r\n").encode()
                + body
            )
            form = {}
            for part in message.iter_parts():
                name = part.get_param("name", header="content-disposition")
                form[name] = (part.get_payload(decode=True) or b"").decode("utf-8", "replace")
            level = {
                "level_code": form.get("level_code"),
                "level_name": form.get("level_name"),
                "level_desc": form.get("level_desc"),
                "icon_color": form.get("icon_color"),
                "icon_zip_name": form.get("icon_zip_name"),
                "toneInfo": {"file_name": form.get("tone_id")},
            }
            levels.append(level)
            if level["level_code"] == "02":
                self.send_json({"result": 4099, "msg": "duplicate alarm level identity"})
                return
            self.send_json({"result": 0, "code": 0, "msg": ""})
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length).decode("utf-8"))
        if body.get("cmd_name") == "query_alert_tone":
            self.send_json(
                {
                    "result": 0,
                    "total": 3,
                    "data": [
                        {"file_name": "CriticalAlarm.wav"},
                        {"file_name": "MediumAlarm.wav"},
                        {"file_name": "CommonlyAlarm.wav"},
                    ],
                }
            )
        elif body.get("cmd_name") == "taskmgr_query_police_incident_alarm_level":
            self.send_json(
                {
                    "result": 0,
                    "page_info": {"max_page": 1, "page_number": 1, "page_size": 100},
                    "alarm_level_list": levels or None,
                }
            )
        else:
            self.send_json({"result": 99, "msg": "unsupported command"})


parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, required=True)
args = parser.parse_args()
HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
