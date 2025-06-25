CREATE DATABASE IF NOT EXISTS janus_db;
USE janus_db;

CREATE TABLE IF NOT EXISTS users (
    id               INT AUTO_INCREMENT PRIMARY KEY,
    username         VARCHAR(100)  NOT NULL UNIQUE,
    email            VARCHAR(150)  NOT NULL UNIQUE,
    password         VARCHAR(255)  NOT NULL,
    totp_code        VARCHAR(6)    DEFAULT NULL,
    totp_expires_at  DATETIME      DEFAULT NULL,
    is_admin         BOOLEAN       NOT NULL DEFAULT 0,
    created_at       TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    password_changed_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

INSERT IGNORE INTO users (
    username,
    email,
    password,
    is_admin
)
VALUES (
    'janusadmin',
    'janusadmin@janus.fr',
    '$2y$12$VvxSEERinoO09Q1mQb8TguQKkavfjxj4PZbo.nbNr0gahGyIp/VEm',
    TRUE
);

CREATE TABLE IF NOT EXISTS remote_connections (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    user_id    INT           NOT NULL,
    name       VARCHAR(100)  NOT NULL,
    protocol   ENUM('ssh', 'vnc', 'rdp') NOT NULL,
    host       VARCHAR(255)  NOT NULL,
    port       INT,
    username   VARCHAR(100)  NOT NULL,
    password   VARCHAR(255),
    created_at TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) 
        REFERENCES users(id) 
        ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS connection_access (
    user_id        INT NOT NULL,
    connection_id  INT NOT NULL,
    PRIMARY KEY    (user_id, connection_id),
    FOREIGN KEY    (user_id) 
        REFERENCES users(id) 
        ON DELETE CASCADE,
    FOREIGN KEY    (connection_id) 
        REFERENCES remote_connections(id) 
        ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS hosts (
    id           INT AUTO_INCREMENT PRIMARY KEY,
    hostname     VARCHAR(255) NOT NULL UNIQUE,
    ip_addr      VARBINARY(16),
    description  TEXT,
    created_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uniq_host (hostname, ip_addr)
);

INSERT INTO hosts (hostname, ip_addr, description)
VALUES ('host_210', INET_ATON('192.168.43.59'), 'Test machine');


CREATE TABLE IF NOT EXISTS services (
    id        INT AUTO_INCREMENT PRIMARY KEY,
    host_id   INT NOT NULL,
    proto     ENUM('SSH', 'RDP', 'VNC', 'TELNET', 'HTTPS') NOT NULL,
    port      SMALLINT UNSIGNED NOT NULL,
    UNIQUE KEY uniq_srv (host_id, proto, port),
    FOREIGN KEY (host_id)
        REFERENCES hosts(id)
        ON DELETE CASCADE
);

INSERT INTO services (host_id, proto, port)
VALUES (
    (SELECT id FROM hosts WHERE hostname='host_210'),
    'SSH',
    22
);

CREATE TABLE IF NOT EXISTS access_rules (
    user_id     INT NOT NULL,
    service_id  INT NOT NULL,
    allow       BOOLEAN         NOT NULL DEFAULT 1,
    created_at  TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, service_id),
    FOREIGN KEY (user_id) 
        REFERENCES users(id) 
        ON DELETE CASCADE,
    FOREIGN KEY (service_id) 
        REFERENCES services(id) 
        ON DELETE CASCADE
);

INSERT IGNORE INTO access_rules (user_id, service_id, allow)
VALUES (
    (SELECT id FROM users    WHERE username='janusadmin'),
    (SELECT id FROM services WHERE host_id=(SELECT id FROM hosts WHERE hostname='host_210') 
                                 AND proto='SSH' AND port=22),
    TRUE
);

CREATE TABLE IF NOT EXISTS credentials (
    id           INT AUTO_INCREMENT PRIMARY KEY,
    user_id      INT NOT NULL,
    service_id   INT NOT NULL,
    cred_type    ENUM('SSH_KEY', 'PASSWORD', 'CERTIFICATE') NOT NULL,
    secret_enc   BLOB        NOT NULL,
    valid_from   DATETIME    NULL,
    valid_to     DATETIME    NULL,
    UNIQUE KEY uniq_cred (user_id, service_id, cred_type),
    FOREIGN KEY (user_id) 
        REFERENCES users(id) 
        ON DELETE CASCADE,
    FOREIGN KEY (service_id) 
        REFERENCES services(id) 
        ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS sessions (
    id           INT AUTO_INCREMENT PRIMARY KEY,
    user_id      INT NOT NULL,
    service_id   INT NOT NULL,
    started_at   DATETIME        NOT NULL,
    ended_at     DATETIME        NULL,
    outcome      ENUM('SUCCESS', 'FAILURE', 'INTERRUPTED') NOT NULL,
    log_path     VARCHAR(512)    NULL,
    FOREIGN KEY (user_id)
        REFERENCES users(id),
    FOREIGN KEY (service_id)
        REFERENCES services(id)
);
