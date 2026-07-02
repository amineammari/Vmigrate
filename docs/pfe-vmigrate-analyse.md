# Dossier d'analyse PFE - VMigrate

Ce document analyse le depot `/home/amin/Desktop/vm-migrator` pour alimenter les chapitres 3 et 4 d'un rapport PFE DevOps / Cloud Engineering. Il est base uniquement sur les fichiers presents dans le depot au moment de l'analyse. Les secrets trouves dans `.env` ne sont pas reproduits.

## 1. Vue Globale Du Projet

Nom du projet : **VMigrate** ou **VM Migrator** selon les fichiers. Le README nomme le produit "VMigrate: VMware to OpenStack Migration Platform". Le code et les conteneurs utilisent `vm-migrator`, `vmigrate-*` et le logo/branding frontend "VMigrate".

Objectif principal : automatiser une migration de machines virtuelles depuis VMware Workstation, VMware ESXi ou vCenter vers OpenStack. La chaine couvre la decouverte des VMs, la selection, la planification, la conversion disque, la validation, l'import OpenStack et la creation d'une instance cible.

Problematique resolue : une migration VMware vers OpenStack est manuelle, fragile et longue. Elle implique l'inventaire VMware, l'acces datastore, la conversion de formats VMDK vers QCOW2 ou RAW, l'adaptation reseau du guest, l'upload Glance, la creation Cinder/Nova/Neutron et le suivi des echecs. VMigrate centralise ces operations dans une interface web, persiste l'etat et delege les operations longues a Celery.

Cas d'utilisation reels couverts par le depot :

- connecter un endpoint VMware ESXi ou vCenter depuis l'interface ;
- decouvrir les VMs via pyVmomi et stocker leurs CPU, RAM, disques, NICs, power state et metadonnees ;
- connecter un endpoint OpenStack / DevStack via openstacksdk ;
- lister images, flavors, networks, routers, floating IP disponibles ;
- selectionner une ou plusieurs VMs et parametrer flavor, CPU, RAM, reseau, IP fixe, floating IP, disques, stockage local/NFS ;
- creer des `MigrationJob` et les envoyer a Celery ;
- executer conversion reelle si `ENABLE_REAL_CONVERSION=true`, sinon produire un plan dry-run ;
- convertir via `virt-v2v`, `qemu-img`, Ansible optionnel ou workflow NFS ;
- valider images disque avec `qemu-img`, `virt-filesystems`, `virt-df` et logique de comparaison ;
- uploader les disques convertis dans Glance, creer des volumes Cinder, booter une instance Nova depuis volume, attacher les disques restants et floating IP ;
- rollback automatique sur echec avec suppression artefacts locaux, images, volumes et serveurs ;
- monitorer dashboard, jobs, logs synthetiques et provisioning Terraform.

Architecture globale :

```text
Utilisateur
  |
  v
Frontend React/Vite/Nginx
  |
  v
Django REST API + JWT + RBAC
  |                  |
  v                  v
MariaDB/SQLite       Redis broker/result backend
                     |
                     v
              Celery worker / conversion-worker
                     |
      +--------------+---------------+
      |              |               |
      v              v               v
 VMware ESXi/vCenter virt-v2v/qemu/libguestfs OpenStack SDK/Terraform
      |                              |
      v                              v
 VMDK/datastore                 Glance/Cinder/Nova/Neutron
```

Workflow metier complet VMware -> OpenStack :

1. L'utilisateur s'authentifie via `/api/auth/login`. Le frontend stocke access token, refresh token et profil utilisateur.
2. Il ajoute un endpoint VMware dans `InfraManagementPage` ou `VMwareInventoryPage`. L'API `/api/vmware/endpoints/connect` cree une `VmwareEndpointSession` avec mot de passe chiffre par `django_cryptography`.
3. Pour vCenter, la decouverte est synchrone dans la vue ; pour ESXi, la vue envoie `discover_vmware_vms.delay(...)` vers Celery.
4. `discover_vmware_vms` instancie `ESXiProvider`, `VCenterProvider` ou `WorkstationVMwareClient`, lit l'inventaire et upsert des `DiscoveredVM`.
5. L'utilisateur choisit VM(s), endpoint OpenStack, projet OpenStack, flavor/reseau/IP/disques. Le frontend appelle `/api/migrations/from-vmware`.
6. `CreateMigrationFromVMwareSerializer` valide les sessions, l'existence des VMs, les doublons, les flavors, networks, IP fixes et floating IP contre OpenStack.
7. La vue cree un `MigrationJob` par VM avec `conversion_metadata` contenant source, destination, sessions, projet, overrides et `use_nfs`.
8. La vue envoie chaque job a Celery avec `start_migration.delay(job.id)`.
9. `start_migration` fait progresser le job dans la machine d'etats : `PENDING -> DISCOVERED -> PRECHECK -> SNAPSHOT_CREATED -> DISK_ANALYZING -> CONVERTING -> BLOCK_VALIDATING -> UPLOADING -> DEPLOYED -> VERIFIED`.
10. Le precheck construit un `ConversionPlan` dans `conversion.py`, verifie la VM, les disques, VDDK/libguestfs et les chemins.
11. Si active, un snapshot ESXi est cree via `snapshot_manager.create_vm_snapshot`. Dans `.env` actuel, `ENABLE_ESXI_MIGRATION_SNAPSHOT=false`, donc cette etape est sautee malgre `ENABLE_ROLLBACK=true`.
12. La conversion utilise `virt-v2v -i libvirt -ic esx://... -it vddk ... -o local -of qcow2` pour ESXi/VDDK, `qemu-img` pour les disques workstation, ou un playbook Ansible si `ENABLE_ANSIBLE_CONVERSION=true`.
13. Les artefacts sont inspectes, le disque systeme est identifie, la remediation reseau guest Linux peut injecter un service de self-heal.
14. `validate_qcow2_images` et les checks filesystem valident les disques.
15. `_run_openstack_deployment` connecte OpenStack, choisit flavor/reseau, upload chaque disque comme image Glance, cree volumes Cinder, boote Nova depuis le volume systeme, attache les autres volumes, ajoute security group baseline et floating IP si demande.
16. La validation finale verifie images actives, serveur ACTIVE, volumes in-use, reseau present et attachements. Le job passe `VERIFIED`.
17. En cas d'erreur, le job passe `FAILED`, un log persistant est ecrit dans `error_logs`, puis `rollback_migration` nettoie fichiers et ressources OpenStack avant `ROLLED_BACK` si possible.

## 2. Arborescence Complete Et Role Des Dossiers

Arborescence utile, en excluant les contenus volumineux de `venv`, `.venv`, `frontend/node_modules`, `offline/wheels`, `offline/npm-cache`, `frontend/dist` et `.git` :

```text
vm-migrator/
├── .env
├── .env.example
├── README.md
├── docs/
│   ├── ENV_SETUP.md
│   ├── architecture.md
│   └── container-architecture.md
├── backend/
│   ├── manage.py
│   ├── requirements.txt
│   ├── db.sqlite3
│   ├── core/
│   │   ├── settings.py
│   │   ├── urls.py
│   │   ├── celery.py
│   │   ├── logging.py
│   │   └── services/
│   │       ├── storage.py
│   │       ├── nfs_storage.py
│   │       └── storage_example.py
│   ├── users/
│   │   ├── models.py
│   │   ├── serializers.py
│   │   ├── views.py
│   │   ├── middleware.py
│   │   ├── urls.py
│   │   ├── admin.py
│   │   └── migrations/
│   └── migrations/
│       ├── models.py
│       ├── serializers.py
│       ├── views.py
│       ├── urls.py
│       ├── tasks.py
│       ├── conversion.py
│       ├── disk_formats.py
│       ├── disk_inspection.py
│       ├── filesystem_check.py
│       ├── block_validation.py
│       ├── network_remediation.py
│       ├── openstack_client.py
│       ├── openstack_deployment.py
│       ├── vmware_client.py
│       ├── snapshot_manager.py
│       ├── vmdk_download.py
│       ├── ansible_runner.py
│       ├── terraform_runner.py
│       ├── host_executor.py
│       ├── libguestfs_runtime.py
│       ├── virt_v2v_runtime.py
│       ├── os_profile.py
│       ├── permissions.py
│       ├── initialization.py
│       ├── tests.py
│       ├── tests_auth_session_worker.py
│       ├── management/commands/terraform_apply.py
│       └── migrations/
├── frontend/
│   ├── package.json
│   ├── vite.config.js
│   ├── nginx.conf
│   ├── vmigrate-logo.svg
│   ├── public/
│   └── src/
│       ├── App.jsx
│       ├── main.jsx
│       ├── App.css
│       ├── index.css
│       ├── api/
│       ├── auth/
│       ├── components/
│       ├── contexts/
│       └── pages/
├── docker/
│   ├── dockerfiles/
│   ├── entrypoints/
│   ├── healthchecks/
│   ├── scripts/
│   ├── worker/preflight.sh
│   └── libguestfs-tools.conf
├── docker-compose.yml
├── docker-compose.conversion.yml
├── docker-compose.offline.yml
├── ansible/
│   ├── inventory/hosts.ini
│   └── playbooks/
│       ├── conversion.yml
│       └── devstack-network.yml
├── terraform/
│   ├── provider.tf
│   ├── variables.tf
│   ├── network.tf
│   ├── security.tf
│   ├── outputs.tf
│   └── modules/
│       ├── base_project/
│       ├── network/
│       └── security_groups/
├── offline/
│   ├── README.md
│   ├── images/
│   ├── terraform-providers/
│   ├── vendor/
│   │   ├── terraform/terraform
│   │   ├── vddk/
│   │   └── nbdkit-vddk-plugin.so
│   ├── wheels/
│   └── npm-cache/
├── scripts/
│   ├── dev-stack.sh
│   ├── install_k8s_tools.sh
│   ├── build-offline-bundle.sh
│   ├── load-offline-bundle.sh
│   ├── validate-offline-artifacts.sh
│   └── validate-offline-deployment.sh
├── shared-images/
├── source-vm-prepare.sh
└── test-vm-deploy.sh
```

Role des dossiers :

- `backend/` : API Django, logique metier, Celery, modeles, tests, clients VMware/OpenStack, orchestration conversion/deploiement.
- `backend/core/` : configuration globale Django, Celery, routes racine, logging JSON, stockage local/NFS.
- `backend/users/` : utilisateur custom, roles, JWT, CRUD admin utilisateurs, middleware d'inactivite.
- `backend/migrations/` : coeur fonctionnel de migration, decouverte, conversion, validation, rollback et provisioning.
- `frontend/` : SPA React/Vite, routes, pages d'administration, inventaire, monitoring, configuration reseau.
- `docker/` : Dockerfiles backend/frontend/conversion-worker, entrypoints, healthchecks, scripts runtime libguestfs/VDDK.
- `ansible/` : playbook de conversion `virt-v2v` et playbook de configuration `br-ex` DevStack.
- `terraform/` : IaC OpenStack pour reseau prive, subnet, router, security group.
- `offline/` : artefacts air-gapped : wheels Python, cache npm, VDDK, plugin nbdkit, binaire Terraform.
- `scripts/` : scripts developpement, packaging offline, validation offline, installation d'outils Kubernetes.
- `shared-images/` : artefacts de test QCOW2/XML et temporaires de conversion.
- fichiers `.md` racine : guides d'installation, securite, offline, diagnostics virt-v2v, rapports de resolution.

## 3. Architecture Technique

### Frontend

Technologies : React 19.2, React Router 7.13, Vite 7.3, lucide-react, react-icons, CSS custom. Le build est servi par Nginx, avec proxy `/api` et `/admin` vers `backend:8000`.

Pages :

- `LoginPage.jsx` : authentification JWT.
- `DashboardPage.jsx` : statistiques par statut et liste recente.
- `InfraManagementPage.jsx` : ajout/test/suppression endpoints VMware et OpenStack.
- `VMwareInventoryPage.jsx` : ecran principal de migration, selection VMs, endpoints, projets, flavors, reseaux, IPs, disques.
- `MigrationJobsPage.jsx` : monitoring des jobs et bouton provisioning OpenStack Terraform.
- `JobDetailPage.jsx` : details d'un job, metadata JSON, rollback info.
- `LogsPage.jsx` : logs synthetiques derives des jobs, pas un lecteur des fichiers logs backend.
- `SettingsPage.jsx` : catalogue reseau OpenStack, creation routeur, attachement subnet ; creation network appelee cote frontend mais neutralisee cote backend.
- `UsersPage.jsx` : gestion utilisateurs reservee `SUPER_ADMIN`.

Navigation : `App.jsx` declare `/login`, `/dashboard`, `/infrastructure`, `/inventory`, `/migration-jobs`, `/migrations/:id`, `/logs`, `/settings`, `/users`. `ProtectedRoute` impose authentification et roles. `Layout.jsx` fournit sidebar, topbar, theme, logout.

Clients API : `frontend/src/api/auth.js`, `dashboard.js`, `migrations.js`, `openstack.js`, `users.js`, `vmware.js`. `api/client.js` ajoute `Authorization: Bearer`, parse les erreurs et tente refresh token sur 401.

### Backend

Technologies : Django 4.2.16 dans `requirements.txt`, DRF 3.16.1, SimpleJWT 5.5.1, Celery 5.6.2, Redis 7.1.1, openstacksdk 4.9.0, pyvmomi 9.0.0.0, django-environ, dj-database-url, mysqlclient, django-cryptography.

Note environnement local : le virtualenv `backend/.venv` contient Django 6.0.2, ce qui casse `django_cryptography==1.1` (`django.utils.baseconv` absent). Le fichier `requirements.txt` cible Django 4.2.16. Les tests n'ont pas pu demarrer dans ce venv pour cette raison.

Django apps :

- `users` : `User`, `UserSessionActivity`, JWT, register/login/refresh/me, CRUD users pour super admin.
- `migrations` : `MigrationJob`, `DiscoveredVM`, sessions endpoints, OpenStack provisioning run, API migrations, clients et workers.
- `core` : settings, celery, urls, logging, storage.

Authentification : JWT SimpleJWT. Access token 30 minutes, refresh token 7 jours. `SessionActivityMiddleware` ajoute une expiration par inactivite de 7200 secondes, mais les jobs Celery continuent apres logout/expiration.

Base de donnees : `DATABASE_URL` via `dj_database_url`. `.env` actuel pointe MariaDB `database:3306/vm_migrator`; fallback SQLite `backend/db.sqlite3`. En test, settings bascule vers SQLite `test_db.sqlite3`.

Permissions : permission globale `IsAuthenticated`. `IsSuperAdmin` pour users CRUD. Les migrations sont filtrees par proprietaire sauf super admin. Limite observee : certaines vues endpoints list/detail/close resolvent `VmwareEndpointSession.objects.all()` ou `OpenstackEndpointSession.objects.all()` sans filtrage utilisateur effectif, malgre les messages "must belong to you".

### Orchestration

Redis : broker et result backend Celery (`REDIS_URL=redis://redis:6379/0` en Docker). Service compose `redis:7.2.5-alpine` avec appendonly.

Celery : queues `migrations`, `discovery`, `provisioning`, `celery`. Routing :

- `migrations.start_migration` -> queue `migrations`
- `migrations.rollback_migration` -> queue `migrations`
- `migrations.discover_vmware_vms` -> queue `discovery`
- `migrations.provision_openstack_infra` -> queue `provisioning`

Workers : `conversion-worker` execute virt-v2v/qemu/libguestfs/VDDK/Ansible/Terraform. `beat` publie la decouverte periodique si `ENABLE_PERIODIC_DISCOVERY=true`.

### Outils DevOps Et Cloud

- `virt-v2v` : conversion ESXi/libvirt vers QCOW2 local ; integration VDDK via `-it vddk` et options generees par `virt_v2v_runtime.py`.
- `qemu-img` : detection/conversion des formats workstation et validation `qemu-img check`.
- `libguestfs`, `virt-inspector`, `virt-filesystems`, `virt-df`, `guestfish`, `virt-customize` : inspection OS/filesystem et remediation guest.
- `nbdkit` + VDDK : acces disque VMware performant ; preflight verifie plugin et librairies.
- `Ansible` : option de conversion via playbook `ansible/playbooks/conversion.yml`; playbook DevStack pour `br-ex`.
- `Terraform` : creation reseau prive, subnet, router, security group OpenStack ; declenchement via Celery si `ENABLE_TERRAFORM_INFRA` et `ENABLE_TERRAFORM_FROM_CELERY`.
- `openstacksdk` : lecture catalogue OpenStack et deploiement effectif Glance/Cinder/Nova/Neutron.
- `pyVmomi` : decouverte ESXi/vCenter et snapshot.

## 4. APIs Developpees

Toutes les routes ci-dessous sont sous `/api/`, sauf `/admin/`.

| Methode | URL | Description | Entrees | Sorties principales |
|---|---|---|---|---|
| GET | `/api/health` | Health public | aucune | `{status:"ok"}` |
| POST | `/api/auth/register` | Inscription utilisateur simple | username,email,password | user |
| POST | `/api/auth/login` | Login JWT | username,password | access, refresh, user |
| POST | `/api/auth/refresh` | Refresh JWT | refresh | access |
| GET | `/api/auth/me` | Profil courant | Bearer token | id, username, email, role |
| GET | `/api/users/` | Lister utilisateurs | super admin | liste users |
| POST | `/api/users/` | Creer utilisateur | username,email,password,role | user |
| GET/PUT/PATCH/DELETE | `/api/users/<id>/` | CRUD utilisateur | super admin | user ou 204 |
| GET | `/api/dashboard` | Stats migrations | user_id optionnel super admin | total, stats, 25 migrations |
| GET | `/api/openstack/health` | Resume OpenStack | openstack_endpoint_session_id, project_name | project_id, counts, image_error |
| GET | `/api/openstack/images` | Images Glance | session/projet | `{items,image_error}` |
| GET | `/api/openstack/flavors` | Flavors Nova | session/projet | `{items}` |
| GET | `/api/openstack/networks` | Networks detail, externals, floating IP libres | session/projet | `{items,external_networks,available_floating_ips}` |
| POST | `/api/openstack/networks/create` | Creation network appelee par UI mais neutralisee | payload network | retourne toujours erreur "OpenstackNetworkCreateSerializer has been removed." |
| GET | `/api/openstack/routers` | Lister routeurs | session/projet | `{items}` |
| POST | `/api/openstack/routers/create` | Creer routeur + gateway externe | name, external_network_id, session | router dict |
| POST | `/api/openstack/routers/attach-subnet` | Attacher subnet a routeur | router_id, subnet_id, session | result |
| POST | `/api/openstack/endpoints/test` | Tester credentials OpenStack sans persister | auth_url, username, password, project_name, domaines, region, interface, verify, image override | ok, message, project_id, counts |
| GET | `/api/openstack/endpoints` | Lister sessions OpenStack | token | `{items}` |
| POST | `/api/openstack/endpoints/connect` | Creer session OpenStack et tester | meme payload test | session, images, flavors, networks |
| GET | `/api/openstack/endpoints/<id>` | Detail session OpenStack | id | session |
| GET | `/api/openstack/endpoints/<id>/projects` | Projets Keystone visibles | id | `{items,message}` |
| POST | `/api/openstack/endpoints/close` | Supprimer session OpenStack | openstack_endpoint_session_id | `{ok:true}` |
| POST | `/api/openstack/provision` | Lancer Terraform OpenStack | openstack_endpoint_session_id, var_overrides | run_id, task_id, state |
| GET | `/api/openstack/provision/status` | Dernier run Terraform | token | run/state/message/ready |
| POST | `/api/vmware/endpoints/test` | Tester ESXi/vCenter | type, host, port, username, password, insecure, datacenter | ok, message, vm_count |
| GET | `/api/vmware/endpoints` | Lister sessions VMware | token | `{items}` |
| POST | `/api/vmware/endpoints/connect` | Creer session et decouvrir | payload VMware | session + items decouverts |
| GET | `/api/vmware/endpoints/<id>` | Detail session VMware | id | session |
| POST | `/api/vmware/endpoints/close` | Supprimer session VMware | vmware_endpoint_session_id | `{ok:true}` |
| GET | `/api/vmware/vms` | Lister VMs decouvertes | endpoint_session_id optionnel | `{items}` |
| POST | `/api/vmware/discover-now` | Enqueue discovery | include_workstation, include_esxi, vmware_endpoint_session_id | task_id, queued |
| GET | `/api/tasks/<task_id>` | Etat Celery | task id | task_id,state,ready,successful,result |
| GET | `/api/migrations` | Lister jobs | user_id, username, ordering pour super admin | jobs summary |
| POST | `/api/migrations` | Creer job manuel minimal | vm_name, source, destination | job detail PENDING |
| GET | `/api/migrations/<job_id>` | Detail job | id | job + conversion_metadata |
| POST | `/api/migrations/from-vmware` | Creer jobs depuis VMs decouvertes et enqueue | vmware_endpoint_session_id, openstack_endpoint_session_id, openstack_project_name, vms[] | created_jobs, skipped_jobs |
| POST | `/api/migrations/<job_id>/start` | Re-enqueue migration | job id | task_id, queued |
| POST | `/api/migrations/<job_id>/rollback` | Enqueue rollback | job id, context | task_id, queued |

Payload principal `/api/migrations/from-vmware` :

```json
{
  "vmware_endpoint_session_id": 1,
  "openstack_endpoint_session_id": 2,
  "openstack_project_name": "admin",
  "vms": [
    {
      "name": "vm-source",
      "source": "esxi",
      "vmware_endpoint_session_id": 1,
      "overrides": {
        "flavor_id": "flavor-id",
        "cpu": 2,
        "ram": 4096,
        "extra_disks_gb": [10],
        "network": {"network_id": "net-id", "fixed_ip": "10.0.0.50"},
        "floating_ip": {"mode": "auto", "external_network_id": "public-net-id"},
        "selected_disk_indexes": [0, 1],
        "disk_layout_mode": "individual",
        "use_nfs": false,
        "store_disks_locally": true
      }
    }
  ]
}
```

## 5. Base De Donnees

Modeles Django :

`users.User` herite de `AbstractUser`.

- `email` : unique email ;
- `role` : `SUPER_ADMIN` ou `USER`, defaut `USER` ;
- `created_at` : creation ;
- champs Django standards : username, password hash, first_name, last_name, is_staff, is_active, is_superuser, date_joined, groups, user_permissions.

`users.UserSessionActivity` :

- `user` : OneToOne vers User, cascade ;
- `last_activity` : auto_now ;
- `ip_address` : char 45 ;
- `user_agent` : char 500 ;
- `created_at` : auto_now_add ;
- indexes sur `(user, -last_activity)` et `-last_activity`.

`migrations.MigrationJob` :

- `user` : FK User nullable, SET_NULL, related `migration_jobs` ;
- `vm_name` ;
- `source` et `destination` labels ;
- `status` : enum `PENDING`, `DISCOVERED`, `PRECHECK`, `SNAPSHOT_CREATED`, `DISK_ANALYZING`, `CONVERTING`, `BLOCK_VALIDATING`, `UPLOADING`, `DEPLOYED`, `VERIFIED`, `FAILED`, `ROLLED_BACK` ;
- `conversion_metadata` : JSON ;
- `progress_percent`, `current_step`, `progress_details` ;
- `created_at`, `updated_at`, `started_at`, `completed_at`.

`migrations.DiscoveredVM` :

- `name` ;
- `vmware_endpoint_session` : FK nullable vers `VmwareEndpointSession`, SET_NULL ;
- `source` : `workstation`, `esxi`, `vcenter` ;
- `cpu`, `ram` ;
- `disks` : JSON list ;
- `metadata` : JSON provider-specific ;
- `power_state` ;
- `last_seen` ;
- contrainte unique `(name, source, vmware_endpoint_session)`.

`migrations.VmwareEndpointSession` :

- `user` FK User nullable ;
- `label`, `host`, `port`, `username`, `password` chiffre, `insecure` ;
- `datacenter` pour vCenter/libvirt ;
- `last_test_status`, `last_test_message`, `last_test_at`, `expires_at`, timestamps.

`migrations.OpenstackEndpointSession` :

- `user` FK User nullable ;
- `label`, `auth_url`, `username`, `password` chiffre ;
- `project_name`, `user_domain_name`, `project_domain_name`, `region_name`, `interface`, `identity_api_version`, `verify`, `image_endpoint_override` ;
- status de test, timestamps ;
- methode `to_connect_kwargs()` pour openstacksdk.

`migrations.OpenStackProvisioningRun` :

- `user` FK User nullable ;
- `task_id` unique ;
- `state`, `message` ;
- timestamps.

ERD textuel :

```text
User
├── 1:1 UserSessionActivity
├── 1:N MigrationJob
├── 1:N VmwareEndpointSession
├── 1:N OpenstackEndpointSession
└── 1:N OpenStackProvisioningRun

VmwareEndpointSession
└── 1:N DiscoveredVM

DiscoveredVM
└── reference logique par MigrationJob.conversion_metadata

OpenstackEndpointSession
└── reference logique par MigrationJob.conversion_metadata

MigrationJob
└── conversion_metadata
    ├── conversion/precheck/execution/block_validation/filesystem_validation
    ├── openstack/image_ids/volume_ids/server_id/network/floating_ip
    ├── rollback_actions
    └── requested_spec
```

## 6. Workflow Des Migrations Avec Composants/Fichiers/Fonctions

1. Decouverte VMware
   - Frontend : `VMwareInventoryPage.refreshFromESXi()`.
   - API : `views.discover_now()` ou `views.vmware_endpoint_connect()`.
   - Celery : `tasks.discover_vmware_vms()`.
   - VMware SDK : `vmware_client.ESXiProvider.list_vms()`, `VCenterProvider.list_vms()`, `WorkstationVMwareClient.discover_vms()`.
   - DB : `DiscoveredVM.objects.update_or_create(...)`.

2. Selection VM
   - Frontend : `VMwareInventoryPage.toggleVM()`, `buildOverrides()`, `migrateSelected()`.
   - Donnees : `selected_disk_indexes`, flavor, CPU/RAM, network, IP fixe, floating IP, `use_nfs`.

3. Creation Job
   - API : `views.create_migrations_from_vmware()`.
   - Validation : `CreateMigrationFromVMwareSerializer.validate_vms()`.
   - DB : creation `MigrationJob` avec metadata source/destination/spec.

4. Envoi Celery
   - Appel : `start_migration.delay(job.id)`.
   - Routing : queue `migrations`.

5. Precheck et plan
   - Fichier : `tasks.py`.
   - Fonctions : `_find_discovered_vm_for_job()`, `_effective_target_spec()`, `_build_plan_with_context()`, `conversion.plan_vmware_conversion()`, `_build_precheck_report()`.
   - Verification : chemins workstation, power_state ESXi powered off, password file, VDDK runtime.

6. Snapshot optionnel
   - Fonction : `_create_snapshot_if_needed()`.
   - SDK : `snapshot_manager.create_vm_snapshot()`.
   - Dans `.env` actuel : snapshots ESXi desactives.

7. Analyse disque
   - Fonctions : `collect_source_disk_inventory()`, `infer_sparse_candidate()`, `_guess_system_disk_index_from_source()`.
   - Metadata : `conversion.disk_analysis_stage`.

8. Execution virt-v2v/qemu
   - Workstation : `_execute_workstation_qemu_pipeline()` -> `disk_formats.detect_disk_format()` et `convert_to_openstack_compatible()`.
   - ESXi : `_execute_virt_v2v()` -> `subprocess.run(plan.command_args)` ou `_execute_virt_v2v_on_host()`.
   - Ansible optionnel : `_execute_ansible_conversion()` -> `AnsibleRunner.run_playbook()`.
   - NFS optionnel : `prepare_vm_dirs()`, `download_vmdk_from_esxi()`, `convert_with_qemu_img()`.

9. Post-conversion
   - Fonctions : `_find_output_qcow2_paths()`, `_order_qcow2_paths_for_boot()`, `_inspect_disk_for_system_filesystem()`, `detect_os_profile()`, `apply_guest_network_remediation()`, backup artefacts.

10. Validation block/filesystem
    - Fonctions : `validate_qcow2_images()`, `run_filesystem_consistency_check()`, `compare_partition_layout()`.
    - Etat : `BLOCK_VALIDATING -> UPLOADING`.

11. Import OpenStack
    - Fonction : `_run_openstack_deployment()`.
    - Connexion : `openstack_deployment.connect_openstack()`.
    - Upload : `ensure_uploaded_image()`.
    - Volumes : `ensure_volume_from_image()`, `ensure_empty_volume()`.
    - Instance : `ensure_server_booted_from_volume()`.
    - Attachements : `attach_volume_to_server()`, `wait_for_volume_attachment()`.
    - Acces : `ensure_server_access_baseline()`, `ensure_server_floating_ip()`.

12. Validation finale
    - Fonctions : `verify_server_active()`, `_validate_openstack_disk_attachments()`, `_validate_openstack_post_migration()`.
    - Etat final : `VERIFIED`.

13. Rollback
    - En cas d'echec : `_mark_job_failed()`, `_write_conversion_error_log()`, `_schedule_rollback()`.
    - Tache : `rollback_migration()`.
    - Nettoyage OpenStack : `_rollback_openstack_resources()`.

## 7. Infrastructure Et Environnement De Test Reels

Selon `.env` actuel :

- Base : MariaDB Docker via `mysql://vm_user:<secret>@database:3306/vm_migrator`.
- Redis : `redis://redis:6379/0`.
- VMware : ESXi `192.168.72.172:443`, user `root`, mot de passe masque, insecure TLS, transport `vddk`, VDDK dans `/opt/vmware-vddk`, nbdkit `/usr/bin/nbdkit`.
- OpenStack : DevStack / OpenStack Identity `http://192.168.72.179/identity`, projet `admin`, region `RegionOne`, interface public, verification TLS false.
- Glance override : `http://192.168.72.200:60999`.
- Reseau par defaut OpenStack : `private`.
- External network Terraform : UUID configure dans `TERRAFORM_DEFAULT_VARS_JSON`.
- Conversion : `ENABLE_REAL_CONVERSION=true`, `ENABLE_OPENSTACK_DEPLOYMENT=true`, output `/home/amin/shared-images`, debug virt-v2v actif, libguestfs direct/TCG, kernel embarque.
- Rollback : active ; snapshot ESXi pre-migration desactive.
- Backup artefact : active et requis.
- Discovery periodique : active toutes les 300 secondes.

OpenStack utilise : API Keystone, Glance, Nova, Neutron, Cinder via openstacksdk et Terraform provider OpenStack. Le deploiement cree images, volumes, serveur, security group baseline et floating IP.

VMware utilise : ESXi/vCenter via pyVmomi pour inventaire et snapshot ; ESXi/libvirt/VDDK/nbdkit/virt-v2v pour conversion.

Reseaux : le code permet network target par ID/nom, IP fixe validee dans allocation pools, floating IP disabled/auto/manual, external network par ID/nom. Terraform cree `migrator-private`, `migrator-subnet` `10.30.0.0/24`, `migrator-router`, security group SSH/ICMP.

Hyperviseurs : source VMware ESXi/vCenter ; destination OpenStack Nova hyperviseurs non inventories par le code. Le projet ne liste pas explicitement les hyperviseurs OpenStack.

## 8. Kubernetes Et Deploiement

Dockerfiles presents :

- `backend.Dockerfile` : Python slim, dependances Django, Gunicorn, non-root `appuser`.
- `frontend.Dockerfile` : Node build + Nginx runtime.
- `conversion-worker.Dockerfile` : Python slim avec virt-v2v, qemu-utils, libguestfs, nbdkit, libvirt-clients, Ansible, Terraform, VDDK vendor.
- variantes `*-offline.Dockerfile` et `*-offline-v2.Dockerfile` pour deploiement air-gapped.

Docker Compose :

- `docker-compose.yml` : stack control + worker : db, redis, backend, worker, beat, frontend.
- `docker-compose.conversion.yml` : conversion-worker separe sur reseau externe `vm-migrator-control`.
- `docker-compose.offline.yml` : stack offline complete avec backend, frontend, celery-worker, celery-beat, db, redis.

Kubernetes :

- Aucun dossier `k8s/`, aucun manifest YAML Kubernetes operationnel, aucun Helm chart dans le depot.
- `docs/ENV_SETUP.md` et `scripts/install_k8s_tools.sh` installent kubectl, Helm, kind, ingress-nginx, cert-manager, monitoring, NFS provisioner.
- README et docs parlent de Kubernetes comme possibilite ou exemple, mais les manifests ne sont pas presents.
- RKE2 : aucune configuration RKE2 concrete trouvee.
- Helm Charts : aucun chart applicatif present.
- Ingress : seulement documentation d'installation ingress-nginx, pas de ressource Ingress applicative.
- CI/CD : pas de `.github/workflows`, `.gitlab-ci.yml`, Jenkinsfile ou pipeline present.

## 9. Fonctionnalites Implementees

| Fonctionnalite | Statut | Description |
|---|---|---|
| Authentification JWT | Implemente | Login, refresh, register, me avec SimpleJWT |
| Roles utilisateurs | Implemente | `SUPER_ADMIN` et `USER` |
| CRUD utilisateurs | Implemente | Reserve super admin |
| Expiration inactivite | Implemente | Middleware 2h, jobs independants |
| Bootstrap superadmin | Implemente | Creation idempotente au demarrage |
| Connexion VMware ESXi | Implemente | Session + test + discovery async |
| Connexion vCenter | Partiel | Discovery synchrone, champ datacenter existe mais pas sauvegarde dans la vue connect |
| Connexion OpenStack | Implemente | Session + test + catalogues |
| Inventaire VMware | Implemente | VMs, CPU, RAM, disks, NICs, guest, storage |
| Creation jobs migration | Implemente | Multi-VM, anti-doublon, metadata |
| Conversion reelle | Implemente | virt-v2v/VDDK, qemu-img, Ansible optionnel |
| NFS/local storage | Implemente | storage manager + workflow NFS avec fallback |
| Remediation reseau guest | Implemente | Injection Linux self-heal |
| Upload OpenStack | Implemente | Glance images + Cinder volumes |
| Creation instance OpenStack | Implemente | Boot depuis volume + attachements |
| Floating IP | Implemente | disabled/auto/manual/reuse |
| Security group baseline | Implemente | ICMP, SSH, egress IPv4/IPv6 |
| Rollback | Implemente | fichiers + images + volumes + serveur |
| Dashboard | Implemente | stats et dernieres migrations |
| Monitoring jobs | Implemente | polling jobs + provisioning |
| Logs UI | Partiel | logs synthetiques depuis jobs, pas lecture logs fichiers |
| Terraform provisioning | Implemente mais optionnel | Active par env, via Celery |
| Creation network OpenStack API | Non fonctionnelle | Route existe mais renvoie erreur serializer supprime |
| Kubernetes | Documentation seulement | Pas de manifests/charts |
| CI/CD | Absent | Aucun pipeline |
| Tests unitaires | Presents | Plusieurs classes de tests |
| Execution tests locale | Bloquee | Incompatibilite Django 6 / django-cryptography dans venv |

## 10. Captures Pour Le Rapport

| Capture recommandee | Interface | Emplacement conseille |
|---|---|---|
| `Figure 3.x - Tableau de bord VMigrate` | `/dashboard` | Chapitre 3, presentation application |
| `Figure 3.x - Connexion endpoints VMware/OpenStack` | `/infrastructure` | Architecture fonctionnelle |
| `Figure 4.x - Inventaire VMware decouvert` | `/inventory` | Workflow de migration |
| `Figure 4.x - Parametrage cible OpenStack` | `/inventory`, panneau VM et selectors | Implementation migration |
| `Figure 4.x - Selection disques et IP/floating IP` | `/inventory` detail VM | Migration multi-disques/reseau |
| `Figure 4.x - Monitoring des migrations` | `/migration-jobs` | Orchestration Celery |
| `Figure 4.x - Detail technique d'un job` | `/migrations/<id>` | Traceabilite et audit |
| `Figure 4.x - Logs applicatifs synthetiques` | `/logs` | Suivi operationnel |
| `Figure 4.x - Catalogue reseau OpenStack` | `/settings` | Integration Neutron |
| `Figure 4.x - Gestion utilisateurs` | `/users` | Securite/RBAC |
| `Figure 4.x - OpenStack Horizon instance migree` | Horizon externe | Validation finale |
| `Figure 4.x - VMware ESXi VM source` | vSphere/ESXi externe | Etat source avant migration |

## 11. Realisations Personnelles Valorisees

Realisations visibles dans le depot :

- developpement d'une application Django REST structurante pour migrations ;
- implementation du frontend React complet avec dashboard, inventaire, monitoring, settings et users ;
- integration JWT, roles, session inactivity et bootstrap superadmin ;
- modelisation des jobs, VMs decouvertes, endpoint sessions, provisioning runs ;
- implementation d'une machine d'etats de migration robuste ;
- integration pyVmomi pour ESXi/vCenter ;
- integration openstacksdk pour Keystone/Glance/Nova/Cinder/Neutron ;
- integration virt-v2v, VDDK, nbdkit, libguestfs et qemu-img ;
- workflow de conversion multi-disques avec detection disque systeme ;
- validation block/filesystem post-conversion ;
- remediation reseau guest Linux ;
- rollback automatique local et OpenStack ;
- logs d'erreur persistants pour environnements air-gapped ;
- Dockerisation backend/frontend/worker/beat/db/redis ;
- separation control plane / conversion plane documentee ;
- packaging offline : wheels, npm cache, VDDK, Terraform, scripts ;
- Terraform OpenStack reseau/security group ;
- Ansible conversion et DevStack bridge ;
- scripts de deploiement/test offline (`source-vm-prepare.sh`, `test-vm-deploy.sh`, validate scripts) ;
- documentation technique abondante : architecture, container, offline, diagnostics, securite, guides de resolution.

## 12. Tests

Tests fonctionnels presents :

- auth/register/login/me ;
- users CRUD super admin ;
- session activity et expiration ;
- creation jobs depuis VMs selectionnees ;
- validation serializer overrides disque/reseau ;
- dashboard et APIs OpenStack/VMware partiellement couverts par mocks.

Tests techniques presents :

- detection formats QCOW2/VMDK/VHD/VHDX/raw ;
- wrapper `qemu-img` succes/echec ;
- runtime VDDK, virt-v2v version et options threads ;
- libguestfs env TCG ;
- endpoint image override OpenStack ;
- security group / floating IP helpers ;
- snapshot policy ;
- worker config Celery, queues et progress tracking.

Tests migration :

- tests unitaires `start_migration` avec mocks dans `backend/migrations/tests.py` ;
- artefacts `shared-images/test-sda*.qcow2`, `test.xml` ;
- tests scripts offline dans `test-vm-deploy.sh`.

Tests OpenStack :

- OpenStack client validation, listes images/flavors/networks/projects ;
- Terraform apply wrapper ;
- scripts validation deployment offline.

Tests Kubernetes :

- aucun test Kubernetes applicatif ; seulement documentation et script d'installation outils.

Tests resilience :

- rollback, erreurs virt-v2v, logs persistants ;
- Celery `acks_late`, reject on worker lost, max tasks child ;
- preflight conversion worker.

Resultat d'execution dans l'environnement courant :

- `python` absent ;
- `python3 manage.py test ...` echoue car Django non installe globalement ;
- `backend/.venv/bin/python manage.py test migrations users` echoue avant tests : `django_cryptography` importe `django.utils.baseconv`, absent de Django 6.0.2 installe dans ce venv. Le `requirements.txt` cible pourtant Django 4.2.16. Conclusion : tests ecrits, mais non executables dans le virtualenv actuel sans realigner les dependances.

## 13. Difficultes, Limitations Et Contournements

Problemes documentes ou visibles :

- compatibilite virt-v2v/VDDK : guides `VIRT_V2V_FIX_GUIDE.md`, commits sur VDDK transport et nbdkit ;
- erreur ESXi "server does not support range" geree dans `_process_virt_v2v_output()` avec recommandation VDDK ;
- plugin nbdkit VDDK manquant detecte par `_check_vddk_runtime()` et preflight ;
- environnement Docker sans KVM : libguestfs force TCG, kernel embarque, scripts `embed-container-kernel`, wrapper qemu TCG ;
- `.env` active `VIRT_V2V_DEBUG=true` et `LIBGUESTFS_TRACE`, utile mais verbeux ;
- snapshots ESXi desactives dans `.env`, probablement pour eviter risques/perfs en test ;
- `openstack_network_create` expose une route mais renvoie immediatement une erreur ;
- routes endpoints VMware/OpenStack ne filtrent pas toujours par user malgre RBAC attendu ;
- `terraform_apply_now` existe dans `views.py` mais n'est pas expose dans `urls.py` ;
- mismatch dependances : backend venv Django 6.0.2 contre `requirements.txt` Django 4.2.16 ;
- vCenter `datacenter` est dans serializer/model, utilise au test, mais non persiste lors de `vmware_endpoint_connect` ;
- Kubernetes/RKE2/Helm/CI-CD mentionnes en documentation mais non implementes comme artefacts deployables ;
- presence de `venv`, `.venv`, `node_modules`, `dist`, `.terraform`, `terraform.tfstate`, caches offline et `db.sqlite3` dans le depot : utile pour livraison/test offline, mais lourd et sensible pour un depot production.

Choix architecturaux :

- separation control plane / conversion plane ;
- Celery + Redis pour eviter blocage API ;
- metadata JSON pour conserver details variables de conversion/OpenStack ;
- rollback asynchrone plutot qu'une transaction globale impossible entre fichiers et cloud ;
- endpoint sessions chiffres en DB ;
- OpenStack boot-from-volume plutot que boot direct image, afin de conserver l'architecture disque et attacher plusieurs volumes.

## 14. Architecture Finale ASCII

```text
Utilisateur / Administrateur
│
├── Navigateur Web
│   │
│   └── Frontend React 19 + Vite
│       ├── Dashboard
│       ├── Infrastructure endpoints
│       ├── Inventaire VMware / formulaire migration
│       ├── Monitoring jobs
│       ├── Logs synthetiques
│       ├── Network Config
│       └── Users
│
└── HTTP / JWT Bearer
    │
    v
Nginx frontend
    │ proxy /api /admin
    v
Django REST API / Gunicorn
├── users app
│   ├── JWT SimpleJWT
│   ├── RBAC SUPER_ADMIN/USER
│   └── SessionActivityMiddleware
├── migrations app
│   ├── endpoint sessions VMware/OpenStack
│   ├── DiscoveredVM inventory
│   ├── MigrationJob state machine
│   └── OpenStackProvisioningRun
├── MariaDB / SQLite
└── Redis broker/result backend
    │
    ├── queue discovery
    ├── queue migrations
    ├── queue provisioning
    └── queue celery
        │
        v
Celery Beat + Celery Conversion Worker
├── Discovery
│   └── pyVmomi -> VMware ESXi/vCenter
├── Conversion Planning
│   ├── libvirt esx:// URI
│   ├── VDDK thumbprint
│   └── password file temporaire
├── Optional NFS/local storage
│   └── /var/lib/vm-migrator/images ou /home/amin/shared-images
├── virt-v2v / qemu-img / libguestfs / nbdkit / VDDK
│   ├── VMDK -> QCOW2/RAW
│   ├── disk inspection
│   ├── OS profile detection
│   ├── guest network remediation
│   └── block/filesystem validation
├── Optional Ansible
│   └── ansible/playbooks/conversion.yml
├── Optional Terraform
│   └── terraform/modules/network + security_groups
└── OpenStack Deployment
    ├── Keystone auth
    ├── Glance image upload
    ├── Cinder volume from image
    ├── Nova boot from volume
    ├── Neutron network/fixed IP/floating IP
    ├── Security group baseline
    └── post-validation -> VERIFIED
```
