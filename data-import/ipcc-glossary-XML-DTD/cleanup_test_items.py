"""Delete test items by QID range. Run before a clean test run."""
import requests

API = "http://localhost:8080/api.php"
# QIDs to delete — all test items created during iterative test runs
TO_DELETE = [f"Q{n}" for n in range(200, 250)]

s = requests.Session()
r = s.get(API, params={"action": "query", "meta": "tokens", "type": "login", "format": "json"})
tok = r.json()["query"]["tokens"]["logintoken"]
s.post(API, data={"action": "login", "lgname": "admin", "lgpassword": "adminpass123!", "lgtoken": tok, "format": "json"})
r = s.get(API, params={"action": "query", "meta": "tokens", "format": "json"})
csrf = r.json()["query"]["tokens"]["csrftoken"]

for qid in TO_DELETE:
    r = s.post(API, data={"action": "delete", "title": f"Item:{qid}", "reason": "test cleanup", "token": csrf, "format": "json"})
    result = r.json()
    if "delete" in result:
        print(f"Deleted {qid}")
    elif "error" in result and result["error"]["code"] == "missingtitle":
        pass  # already gone
    else:
        code = result.get("error", {}).get("code", "?")
        print(f"Error {qid}: {code}")
