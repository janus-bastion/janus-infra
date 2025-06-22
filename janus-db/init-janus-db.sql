CREATE DATABASE IF NOT EXISTS janus_db;
USE janus_db;

-- Table des utilisateurs
CREATE TABLE IF NOT EXISTS users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(100) NOT NULL UNIQUE,
    email VARCHAR(150) NOT NULL UNIQUE,
    password VARCHAR(255) NOT NULL,
    totp_code VARCHAR(6) DEFAULT NULL;
    totp_expires_at DATETIME DEFAULT NULL;
    is_admin BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Utilisateur admin par défaut
INSERT IGNORE INTO users (username, email, password, is_admin)
VALUES (
    'janusadmin',
    'janusadmin@janus.fr',
    '$2y$12$VvxSEERinoO09Q1mQb8TguQKkavfjxj4PZbo.nbNr0gahGyIp/VEm',
    TRUE
);

-- Table des connexions distantes
CREATE TABLE IF NOT EXISTS remote_connections (
    id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT NOT NULL,
    name VARCHAR(100) NOT NULL,
    protocol ENUM('ssh', 'vnc', 'rdp') NOT NULL,
    host VARCHAR(255) NOT NULL,
    port INT,
    username VARCHAR(100) NOT NULL,
    password VARCHAR(255),
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

-- Table des droits d’accès aux connexions
CREATE TABLE IF NOT EXISTS connection_access (
    user_id INT NOT NULL,
    connection_id INT NOT NULL,
    PRIMARY KEY (user_id, connection_id),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (connection_id) REFERENCES remote_connections(id) ON DELETE CASCADE
);
