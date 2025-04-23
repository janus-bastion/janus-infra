CREATE DATABASE IF NOT EXISTS janus_db;

USE janus_db;

CREATE TABLE IF NOT EXISTS users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(100) NOT NULL UNIQUE,
    email VARCHAR(150) NOT NULL UNIQUE,
    password VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT IGNORE INTO users (username, email, password)
VALUES (
    'janusadmin',
    'janusadmin@janus.fr',
    '$2y$12$VvxSEERinoO09Q1mQb8TguQKkavfjxj4PZbo.nbNr0gahGyIp/VEm'
);

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
);

