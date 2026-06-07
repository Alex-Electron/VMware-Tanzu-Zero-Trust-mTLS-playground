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

url = "https://10.0.20.80/api/serviceengine-inventory"
resp = session.get(url, headers=headers, verify=False)

if resp.status_code == 200:
    data = resp.json()
    for se in data.get('results', []):
        name = se.get('config', {}).get('name')
        state = se.get('runtime', {}).get('oper_status', {}).get('state')
        reason = se.get('runtime', {}).get('oper_status', {}).get('reason', [''])[0]
        print(f"Name: {name}, State: {state}, Reason: {reason}")
else:
    print(f"Failed to fetch SEs: {resp.status_code}")
