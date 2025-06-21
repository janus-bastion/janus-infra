# Réplication de Base de Données Janus

Cette solution implémente une réplication

## Vue d'ensemble

Le système réplique automatiquement toutes les modifications de la base de données principale vers une instance secondaire. L'architecture repose sur :

- Détection automatique des changements via triggers MySQL
- Synchronisation événementielle avec table de logs
- Gestion transparente des nouvelles tables
- Interface unifiée via un script shell unique

**Composants principaux :**
- Script de gestion : `janus-replication.sh`
- Base source : conteneur `janus-mysql` (port 3306)
- Base réplique : conteneur `janus-mysql-replica` (port 3307)

### Mise en route

2. **Initialiser la réplication**
   ```bash
   cd janus-db
   chmod +x janus-replication.sh
   ./janus-replication.sh setup
   ```

3. **Vérifier l'installation**
   ```bash
   ./janus-replication.sh status
   ```

4. **Activer la synchronisation continue**
   ```bash
   ./janus-replication.sh auto-sync
   ```

## Utilisation

### Commandes principales

**Configuration initiale**
```bash
./janus-replication.sh setup
```
Configure les conteneurs et installe les triggers sur toutes les tables existantes.

**Synchronisation**
```bash
# Synchronisation ponctuelle
./janus-replication.sh sync

# Synchronisation continue (arrêt avec Ctrl+C)
./janus-replication.sh auto-sync
```

**Gestion des sauvegardes**
```bash
# Sauvegarde avec nom automatique
./janus-replication.sh backup

# Sauvegarde nommée
./janus-replication.sh backup nom_sauvegarde

# Restauration
./janus-replication.sh restore fichier_sauvegarde.sql.gz
```

**Monitoring**
```bash
# État détaillé du système
./janus-replication.sh status

# Nettoyage complet
./janus-replication.sh cleanup
```

## Configuration

### Variables d'environnement

Le fichier `.env` permet de personnaliser la configuration :

```bash
cp .env.example .env
```

**Paramètres disponibles :**
```bash
# Base de données source
SOURCE_CONTAINER=janus-mysql
SOURCE_USER=root
SOURCE_PASSWORD=root
SOURCE_DB=janus_db

# Base de données réplique
TARGET_CONTAINER=janus-mysql-replica
TARGET_USER=root
TARGET_PASSWORD=replica_password
TARGET_DB=janus_db

# Intervalle de synchronisation (secondes)
SYNC_INTERVAL=10
```

La base réplique est créée automatiquement lors du premier `setup` si elle n'existe pas.

