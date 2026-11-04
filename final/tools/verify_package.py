"""Offline package verification; no device imports or access."""
import json
from portable_package import verify_files
if __name__=='__main__':print(json.dumps(verify_files(),ensure_ascii=False,indent=2))
