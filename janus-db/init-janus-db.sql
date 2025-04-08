CREATE DATABASE IF NOT EXISTS janus_db;

USE janus_db;

CREATE TABLE IF NOT EXISTS users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(100) NOT NULL UNIQUE,
    email VARCHAR(150) NOT NULL UNIQUE,
    password VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insérer l'utilisateur admin avec mot de passe hashé
INSERT INTO users (username, email, password) 
VALUES (
    'janusadmin', 
    'janusadmin@janus.fr', 
    '$2y$12$VvxSEERinoO09Q1mQb8TguQKkavfjxj4PZbo.nbNr0gahGyIp/VEm'
)
ON DUPLICATE KEY UPDATE 
    email = VALUES(email),
    password = VALUES(password);

CREATE TABLE remote_connections (
    id int NOT NULL AUTO_INCREMENT,
    user_id int NOT NULL,
    name varchar(100) NOT NULL,
    protocol enum('ssh','vnc','rdp') NOT NULL,
    host varchar(255) NOT NULL COMMENT 'IP ou hostname',
    port int DEFAULT NULL,
    username varchar(100) NOT NULL,
    password varchar(255) DEFAULT NULL,
    created_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY `user_id` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

