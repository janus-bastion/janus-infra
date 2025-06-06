<a id="readme-top"></a> 

<h1><center>Janus infra</center></h1>

<div align="center">
  <a href="https://github.com/janus-bastion">
    <img src="https://github.com/janus-bastion/janus-frontend/blob/main/janus-website/janus-logo.png" alt="Janus Bastion Logo" width="160" height="160" />
  </a>

  <p><em>The infrastructure orchestrator of the Janus project. It deploys and manages the bastion’s containers, services, and configurations using docker and GitHub Actions.
</em></p>

  <table align="center">
    <tr>
      <th>Author</th>
      <th>Author</th>
      <th>Author</th>
      <th>Author</th>
    </tr>
    <tr>
      <td align="center">
        <a href="https://github.com/nathanmartel21">
          <img src="https://github.com/nathanmartel21.png?size=115" width="115" alt="@nathanmartel21" /><br />
          <sub>@nathanmartel21</sub>
        </a>
        <br /><br />
        <a href="https://github.com/sponsors/nathanmartel21">
          <img src="https://img.shields.io/badge/sponsor-30363D?style=for-the-badge&logo=GitHub-Sponsors&logoColor=white" alt="Sponsor nathanmartel21" />
        </a>
      </td>
      <td align="center">
        <a href="https://github.com/xeylou">
          <img src="https://github.com/xeylou.png?size=115" width="115" alt="@xeylou" /><br />
          <sub>@xeylou</sub>
        </a>
        <br /><br />
        <a href="https://github.com/sponsors/xeylou">
          <img src="https://img.shields.io/badge/sponsor-30363D?style=for-the-badge&logo=GitHub-Sponsors&logoColor=white" alt="Sponsor xeylou" />
        </a>
      </td>
      <td align="center">
        <a href="https://github.com/Djegger">
          <img src="https://github.com/Djegger.png?size=115" width="115" alt="@Djegger" /><br />
          <sub>@Djegger</sub>
        </a>
        <br /><br />
        <a href="https://github.com/sponsors/Djegger">
          <img src="https://img.shields.io/badge/sponsor-30363D?style=for-the-badge&logo=GitHub-Sponsors&logoColor=white" alt="Sponsor Djegger" />
        </a>
      </td>
      <td align="center">
        <a href="https://github.com/Warsgo">
          <img src="https://github.com/Warsgo.png?size=115" width="115" alt="@Warsgo" /><br />
          <sub>@Warsgo</sub>
        </a>
        <br /><br />
        <a href="https://github.com/sponsors/Warsgo">
          <img src="https://img.shields.io/badge/sponsor-30363D?style=for-the-badge&logo=GitHub-Sponsors&logoColor=white" alt="Sponsor Warsgo" />
        </a>
      </td>
    </tr>
  </table>
</div>

---

## Contents

- [`janus-compose.yaml/`](./janus-compose.yaml/): Central docker compose file to orchestrate all infrastructure services.
- [`janus-certs/`](./janus-certs/): SSL certificates and configuration handling.
- [`janus-db/`](./janus-db/): Database setup and initialization scripts.
- [`janus-haproxy/`](./janus-haproxy/): Load balancer configuration using HAProxy.
- [`.github/workflows/`](./.github/workflows/): CI/CD workflows including Docker image scanning with Grype.

## Features

- Docker Compose-based deployment for full infrastructure orchestration.
- HAProxy-based load balancing.
- Modular and extensible directory structure.
- Automatic vulnerability scanning of Docker images using Grype via GitHub Actions.
- SSL/TLS certificate configuration and management.

## Requirements

- [![Git](https://img.shields.io/badge/GIT-E44C30?style=for-the-badge&logo=git&logoColor=white)](https://git-scm.com/)

- [![Docker](https://img.shields.io/badge/Docker-2CA5E0?style=for-the-badge&logo=docker&logoColor=white)](https://www.docker.com/)

- [![Docker Compose](https://img.shields.io/badge/Docker%20Compose-2496ED?style=for-the-badge&logo=docker&logoColor=white)](https://docs.docker.com/compose/)

- [![Bash](https://img.shields.io/badge/GNU%20Bash-4EAA25?style=for-the-badge&logo=GNU%20Bash&logoColor=white)](https://www.gnu.org/software/bash/)

- `xdg-open` (for Linux GUI environments - *but not mandatory*)

## Notes

- Designed for containerized environments with emphasis on security, performance, and modularity.
- Grype scanning is automatically triggered on push or PRs to ensure container integrity and compliance.
- Contributions welcome via pull requests.

## License

This project is licensed under the GNU General Public License v3.0 [GPL-3.0](https://github.com/janus-bastion/.github/blob/main/LICENSE).  
See the `LICENSE` file for more details.
