import sys
from . import core,web
if __name__=='__main__':
    if len(sys.argv)>1 and sys.argv[1]=='worker':core.worker()
    elif len(sys.argv)>1 and sys.argv[1]=='web':web.main()
    else:print('Usage: python3 -m tessentry [web|worker]')
