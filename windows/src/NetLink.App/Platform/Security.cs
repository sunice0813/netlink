using System.IO;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using NetLink.Core;

namespace NetLink.App.Platform;

/// 凭据文件用 DPAPI 加密：只有当前 Windows 用户在这台电脑上能解开。
public sealed class DpapiProtector : ISecretProtector
{
    private static readonly byte[] Entropy = "NetLink.Credentials.v1"u8.ToArray();

    public byte[] Protect(byte[] plain) => ProtectedData.Protect(plain, Entropy, DataProtectionScope.CurrentUser);

    public byte[] Unprotect(byte[] sealedBytes) => ProtectedData.Unprotect(sealedBytes, Entropy, DataProtectionScope.CurrentUser);
}

/// 私密文件（凭据、导入的私钥、带机密的导出文件）只留当前用户能访问。
/// Windows 的 OpenSSH 对私钥要求同样严格：别的用户能读，ssh.exe 会拒绝使用它。
public sealed class WindowsPrivateFiles : IPrivateFiles
{
    public void Restrict(string path) => KeyAcl.Restrict(path);
}

public static class KeyAcl
{
    private static SecurityIdentifier CurrentUser => WindowsIdentity.GetCurrent().User!;

    public static void Restrict(string path)
    {
        var info = new FileInfo(path);
        var security = new FileSecurity();
        security.SetOwner(CurrentUser);
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(CurrentUser, FileSystemRights.FullControl, AccessControlType.Allow));
        info.SetAccessControl(security);
    }

    /// 除了当前用户、SYSTEM 和管理员组，还有别人能读：ssh.exe 会报 UNPROTECTED PRIVATE KEY FILE。
    public static bool TooOpen(string path)
    {
        try
        {
            var security = new FileInfo(path).GetAccessControl();
            var allowed = new HashSet<SecurityIdentifier>
            {
                CurrentUser,
                new(WellKnownSidType.LocalSystemSid, null),
                new(WellKnownSidType.BuiltinAdministratorsSid, null),
            };
            foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
            {
                if (rule.AccessControlType != AccessControlType.Allow) continue;
                if ((rule.FileSystemRights & (FileSystemRights.ReadData | FileSystemRights.Read)) == 0) continue;
                if (rule.IdentityReference is SecurityIdentifier sid && !allowed.Contains(sid)) return true;
            }
            return false;
        }
        catch
        {
            return false;
        }
    }
}
