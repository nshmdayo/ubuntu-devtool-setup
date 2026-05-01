If you need a dev user, just do it.
```
apt update
apt install -y sudo

useradd -m -s /bin/bash dev
usermod -aG sudo dev
passwd dev
```

Change user
```
su - dev
```
