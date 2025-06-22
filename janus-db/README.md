# Janus Database Replication Janus

This solution implements database replication.
 
## Overview

The system automatically replicates all changes from the primary database to a secondary instance. The architecture relies on:

- Automatic change detection via MySQL triggers
- Event-driven synchronization using a log table
- Transparent management of new tables
- Unified interface through a single shell script

**Main components:**
- Management script: `janus-replication.sh`
- Source database: container `janus-mysql` (port 3306)
- Replica database: container `janus-mysql-replica` (port 3307)

### Getting Started

2. **Initialize replication**
   ```bash
   cd janus-db
   chmod +x janus-replication.sh
   ./janus-replication.sh setup
   ```

3. **Verify installation**
   ```bash
   ./janus-replication.sh status
   ```

4. **Enable continuous synchronization**
   ```bash
   ./janus-replication.sh auto-sync
   ```

## Usage

### Main commands

**Initial setup**
```bash
./janus-replication.sh setup
```
Configures the containers and installs triggers on all existing tables.

**Synchronization**
```bash
# One-time synchronization
./janus-replication.sh sync

# Continuous synchronization (stop with Ctrl+C)
./janus-replication.sh auto-sync
```

**Backup management**
```bash
# Backup with automatic name
./janus-replication.sh backup

# Named backup
./janus-replication.sh backup backup_name

# Restore
./janus-replication.sh restore backup_file.sql.gz
```

**Monitoring**
```bash
# Detailed system status
./janus-replication.sh status

# Full cleanup
./janus-replication.sh cleanup
```

## Configuration

### Environment variables


The `.env` file allows customization of the configuration:

```bash
cp .env.example .env
```

The replica database is automatically created during the first `setup` if it does not exist.
