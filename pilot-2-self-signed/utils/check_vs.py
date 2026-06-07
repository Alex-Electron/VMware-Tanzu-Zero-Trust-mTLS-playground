import requests
import urllib3
import json

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

session = requests.Session()
login_url = "https://10.0.20.80/login"
payload = {"username": "admin", "password": "VMware1!"}

session.post(login_url, json=payload, verify=False)
csrf_token = session.cookies.get('csrftoken')

headers = {
    "X-CSRFToken": csrf_token,
    "Referer": "https://10.0.20.80",
    "Content-Type": "application/json"
}

url_vs = "https://10.0.20.80/api/virtualservice-inventory"
resp = session.get(url_vs, headers=headers, verify=False)
if resp.status_code == 200:
    for vs in resp.json().get('results', []):
        name = vs.get('config', {}).get('name')
        state = vs.get('runtime', {}).get('oper_status', {}).get('state')
        reason = vs.get('runtime', {}).get('oper_status', {}).get('reason', [''])[0]
        print(f"VS: {name}, State: {state}, Reason: {reason}")
else:
    print(f"Failed to fetch VS inventory: {resp.status_code}")
