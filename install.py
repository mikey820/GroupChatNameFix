import paramiko
import os
import sys

def install_deb(host, user, password, deb_path):
    print(f"Connecting to {host}...")
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        ssh.connect(host, username=user, password=password)
        print("Connected.")

        sftp = ssh.open_sftp()
        remote_path = f"/tmp/{os.path.basename(deb_path)}"
        print(f"Uploading {deb_path} to {remote_path}...")
        sftp.put(deb_path, remote_path)
        sftp.close()
        print("Upload complete.")

        print("Installing package...")
        stdin, stdout, stderr = ssh.exec_command(f"dpkg -i {remote_path}")
        print(stdout.read().decode())
        print(stderr.read().decode())

        print("Restarting imagent...")
        ssh.exec_command("killall -9 imagent")
        print("Done.")

        ssh.close()
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    deb = r"C:\Users\mikey\GroupChatNameFix\build-out\com.mikey820.groupchatnamefix_1.0.0_iphoneos-arm.deb"
    install_deb("192.168.1.221", "root", "alpine", deb)
