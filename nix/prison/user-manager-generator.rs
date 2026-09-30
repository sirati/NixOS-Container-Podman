use std::{env, fs, io, path::Path};

const USERS: &str = include_str!(env!("PRISON_USERS_FILE"));

fn account_uid(passwd: &str, user: &str) -> io::Result<u32> {
    let mut matches = passwd.lines().filter_map(|line| {
        let mut fields = line.split(':');
        (fields.next()? == user).then(|| fields.nth(1).and_then(|uid| uid.parse().ok())).flatten()
    });
    let uid = matches.next().ok_or_else(|| io::Error::other(format!("missing local prison account {user}")))?;
    if matches.next().is_some() {
        return Err(io::Error::other(format!("duplicate local prison account {user}")));
    }
    Ok(uid)
}

fn generate(output: &Path, passwd: &str) -> io::Result<()> {
    for user in USERS.lines() {
        if user.is_empty() || !user.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b)) {
            return Err(io::Error::other("invalid prison account name"));
        }
        let uid = account_uid(passwd, user)?;
        let directory = output.join(format!("prison-user-{user}.target.d"));
        fs::create_dir_all(&directory)?;
        fs::write(directory.join("account.conf.tmp"), format!(
            "[Unit]\nRequires=user@{uid}.service\nAfter=user@{uid}.service\n"
        ))?;
        fs::rename(directory.join("account.conf.tmp"), directory.join("account.conf"))?;
    }
    Ok(())
}

fn main() {
    let result = (|| {
        let output = env::args_os().nth(1).ok_or_else(|| io::Error::other("missing generator output directory"))?;
        generate(Path::new(&output), &fs::read_to_string("/etc/passwd")?)
    })();
    if let Err(error) = result {
        eprintln!("prison-user-managers: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dependency_uses_the_service_account_not_the_manager_account() {
        let passwd = "root:x:0:0::/root:/bin/sh\nbridge:x:994:994::/var/lib/bridge:/sbin/nologin\n";
        assert_eq!(account_uid(passwd, "bridge").unwrap(), 994);
        assert!(account_uid(passwd, "brid").is_err());
        assert!(account_uid("bridge:x:not-a-uid:994::/:/bin/sh", "bridge").is_err());
        assert!(account_uid(&(passwd.to_owned() + passwd), "bridge").is_err());
    }
}
