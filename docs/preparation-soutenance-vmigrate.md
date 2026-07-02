# Preparation soutenance technique - VMigrate

Ce document est base sur le depot local `/home/amin/Desktop/vm-migrator` lu le 30 juin 2026. Il reference les fichiers reels du projet et prepare une soutenance exigeante sur VMigrate, plateforme d'automatisation de migration de VMs VMware vers OpenStack.

## 1. Explication Jury

### Besoin

VMigrate repond au besoin de migrer des machines virtuelles VMware, principalement ESXi/vCenter et aussi Workstation selon le code, vers OpenStack avec moins d'operations manuelles. Une migration classique oblige l'equipe a inventorier les VMs, recuperer les disques VMDK, convertir les formats, adapter le reseau de l'OS invite, importer dans Glance, creer des volumes Cinder, booter une instance Nova, attacher le reseau Neutron, puis diagnostiquer les echecs.

### Probleme

Le probleme n'est pas seulement la conversion VMDK vers QCOW2. C'est l'orchestration complete: credentials VMware/OpenStack, decouverte fiable, choix de flavor/reseau/IP, stockage temporaire local ou NFS, jobs longs, logs, rollback, expiration de session utilisateur, validations disque, upload Glance, boot Nova, attachement Cinder et remediation reseau invite. Le risque principal est une migration partielle: image creee mais serveur non boote, volumes orphelins, disque corrompu, VM inaccessible apres boot.

### Solution

VMigrate propose une interface React/Vite, une API Django REST, une base de donnees, Redis et Celery. Le backend valide les demandes, persiste les jobs, gere l'authentification JWT/RBAC et envoie les longues operations au worker. Le worker execute la decouverte VMware, la conversion `virt-v2v`/`qemu-img`, les checks `libguestfs`, la remediation reseau, l'upload OpenStack et le rollback.

Fichiers principaux:

- API et orchestration HTTP: `backend/migrations/views.py`
- Etat et modeles: `backend/migrations/models.py`
- Workflow asynchrone: `backend/migrations/tasks.py`
- Conversion planning: `backend/migrations/conversion.py`
- VMware: `backend/migrations/vmware_client.py`, `backend/migrations/snapshot_manager.py`
- OpenStack: `backend/migrations/openstack_client.py`, `backend/migrations/openstack_deployment.py`
- Validation disque: `backend/migrations/block_validation.py`, `disk_inspection.py`, `filesystem_check.py`, `disk_formats.py`
- Remediation reseau guest: `backend/migrations/network_remediation.py`
- Frontend principal: `frontend/src/pages/VMwareInventoryPage.jsx`
- Docker: `docker-compose.yml`, `docker-compose.conversion.yml`, `docker/dockerfiles/*`
- Kubernetes: `kubernetes/*.yaml`
- Terraform: `terraform/*.tf`, `terraform/modules/*`
- Ansible: `ansible/playbooks/conversion.yml`, `ansible/playbooks/devstack-network.yml`

### Architecture

VMigrate separe le controle et l'execution lourde.

- Frontend: SPA React/Vite servie par Nginx, proxy `/api` vers Django.
- Backend: Django/DRF, JWT SimpleJWT, RBAC, modeles, serializers, API, creation de jobs.
- DB: MariaDB par defaut en Docker/Kubernetes, SQLite en fallback/test. Attention: si on vous demande PostgreSQL, le depot contient des wheels psycopg2 et une compatibilite via `DATABASE_URL`, mais le deploiement fourni utilise MariaDB.
- Redis: broker et result backend Celery.
- Celery worker: conversion, decouverte, deployment OpenStack, rollback.
- Conversion toolchain: `virt-v2v`, `qemu-img`, `libguestfs`, `virt-filesystems`, `virt-df`, `guestfish`, `virt-customize`, `nbdkit`, VMware VDDK.
- OpenStack: Keystone auth, Glance images, Cinder volumes, Nova servers, Neutron networks, floating IPs.
- IaC optionnelle: Terraform pour reseau/subnet/router/security group OpenStack.
- Ansible optionnel: conversion `virt-v2v` et configuration DevStack `br-ex`.

### Fonctionnement complet

1. L'utilisateur s'authentifie via `/api/auth/login`, implemente dans `backend/users/views.py`.
2. Le frontend stocke access/refresh token dans `frontend/src/auth/storage.js`; `frontend/src/api/client.js` ajoute `Authorization: Bearer` et tente un refresh sur 401.
3. L'utilisateur cree/teste un endpoint VMware ou OpenStack via `InfraManagementPage.jsx` ou `VMwareInventoryPage.jsx`.
4. Les endpoints sont persistes dans `VmwareEndpointSession` et `OpenstackEndpointSession` avec mots de passe chiffres via `django_cryptography` dans `backend/migrations/models.py`.
5. La decouverte VMware appelle `/api/vmware/discover-now`, puis `discover_vmware_vms` dans `backend/migrations/tasks.py`.
6. Les VMs decouvertes sont stockees dans `DiscoveredVM`: CPU, RAM, disques, metadata, power state.
7. L'utilisateur selectionne VMs, flavor, reseau, fixed IP, floating IP, disques, stockage local/NFS.
8. `CreateMigrationFromVMwareSerializer` dans `backend/migrations/serializers.py` valide ownership, doublons, VMs existantes, flavor, network, fixed IP, floating IP.
9. `create_migrations_from_vmware` cree un `MigrationJob` par VM et lance `start_migration.delay(job.id)`.
10. `start_migration` execute la machine d'etats: `PENDING -> DISCOVERED -> PRECHECK -> SNAPSHOT_CREATED -> DISK_ANALYZING -> CONVERTING -> BLOCK_VALIDATING -> UPLOADING -> DEPLOYED -> VERIFIED`, ou `FAILED -> ROLLED_BACK`.
11. Le precheck construit un `ConversionPlan`, verifie chemins, power state ESXi, VDDK, disques.
12. La conversion s'effectue selon source: ESXi/vCenter via `virt-v2v` avec libvirt URI/VDDK, Workstation via `qemu-img`, Ansible si active.
13. Les artefacts QCOW2/RAW sont ordonnes, le disque systeme est detecte, puis valides.
14. Si active, `network_remediation.py` injecte un service systemd de self-heal reseau dans l'image Linux via `virt-customize`.
15. `_run_openstack_deployment` upload chaque disque dans Glance, cree un volume Cinder par image, boote Nova depuis le volume systeme, attache les autres volumes et eventuels volumes vierges.
16. La validation finale verifie image active, serveur ACTIVE, volumes attaches, reseau present et floating IP si demande.
17. En cas d'erreur, le job passe `FAILED`, ecrit les logs, puis rollback selon `ENABLE_ROLLBACK`.

### Cycle d'une migration

Le cycle est: authentification, onboarding endpoints, decouverte, selection, validation, creation job, precheck, snapshot optionnel, analyse disque, conversion, remediation, validation bloc/filesystem, upload Glance, creation volumes, boot Nova, attachement volumes, security group/floating IP, verification, logs/rapport, rollback si echec.

## 2. Decomposition Du Projet

### Racine

- `README.md`: vision produit, architecture, workflow, variables Docker.
- `docs/architecture.md`: architecture code-alignee, state machine, pipeline.
- `docs/container-architecture.md`: separation control plane / conversion plane, offline, preflight.
- `*.md` racine: guides diagnostics, offline, remediation securite, virt-v2v.
- `.env.example` / `.env`: configuration runtime. Ne jamais citer les secrets reels en soutenance.

### `backend/`

Application Django. Dependances dans `backend/requirements.txt`: Django 4.2.16, DRF, SimpleJWT, Celery, Redis, pyVmomi, openstacksdk, mysqlclient, django-cryptography.

- `core/settings.py`: DB, JWT, Celery queues, conversion flags, OpenStack, Terraform, Ansible, logging.
- `core/celery.py`: initialisation Celery.
- `core/logging.py`: logs JSON, filtres app/worker.
- `core/urls.py`: inclusion `/api`.
- `users/models.py`: `User` custom avec role `SUPER_ADMIN` ou `USER`; `UserSessionActivity`.
- `users/middleware.py`: expiration par inactivite.
- `users/views.py`: register, login, refresh, me, CRUD users super admin.
- `migrations/models.py`: `MigrationJob`, `DiscoveredVM`, `VmwareEndpointSession`, `OpenstackEndpointSession`, `OpenStackProvisioningRun`.
- `migrations/serializers.py`: validation endpoint, job, selection VM, overrides, flavor/network/IP.
- `migrations/views.py`: endpoints REST metier.
- `migrations/tasks.py`: workflow Celery principal, rollback, discovery, provisioning.
- `migrations/vmware_client.py`: providers Workstation, ESXi, vCenter via pyVmomi/libvirt metadata.
- `migrations/openstack_client.py`: client catalogue OpenStack pour health, flavors, networks, images, projects.
- `migrations/openstack_deployment.py`: helper Glance/Cinder/Nova/Neutron.
- `migrations/conversion.py`: plan de conversion et commande.
- `migrations/disk_formats.py`: detection/conversion formats disque.
- `migrations/disk_inspection.py`: inventaire disque et sparse.
- `migrations/block_validation.py`: `qemu-img check`.
- `migrations/filesystem_check.py`: `virt-filesystems`, `virt-df`, comparaison layout.
- `migrations/network_remediation.py`: injection self-heal reseau Linux.
- `migrations/os_profile.py`: detection OS Linux/Windows/unknown.
- `migrations/snapshot_manager.py`: snapshot ESXi via pyVmomi.
- `migrations/vmdk_download.py`: telechargement VMDK datastore.
- `migrations/ansible_runner.py`, `terraform_runner.py`, `host_executor.py`: execution externe.
- `migrations/tests.py`, `tests_auth_session_worker.py`: tests conversion, auth/RBAC, sessions, endpoints, helpers.

### `frontend/`

SPA React/Vite.

- `src/App.jsx`: routes protegees.
- `src/api/client.js`: fetch commun, JWT, refresh token.
- `src/api/*.js`: clients auth, VMware, OpenStack, migrations, users.
- `src/contexts/AuthContext.jsx`: etat auth.
- `src/components/ProtectedRoute.jsx`: controle roles.
- `src/pages/LoginPage.jsx`: connexion.
- `src/pages/DashboardPage.jsx`: indicateurs jobs.
- `src/pages/InfraManagementPage.jsx`: endpoints.
- `src/pages/VMwareInventoryPage.jsx`: ecran principal de migration.
- `src/pages/MigrationJobsPage.jsx`: suivi et provisioning.
- `src/pages/JobDetailPage.jsx`: details job.
- `src/pages/SettingsPage.jsx`: reseaux/routers OpenStack.
- `src/pages/UsersPage.jsx`: gestion users super admin.
- `nginx.conf`: sert le build et proxy `/api`, `/admin`.

### `docker/` et Compose

- `docker-compose.yml`: MariaDB, Redis, backend, worker, beat, frontend.
- `docker-compose.conversion.yml`: worker de conversion separe qui rejoint le reseau `vm-migrator-control`.
- `docker-compose.offline.yml`: variante air-gapped.
- `docker/dockerfiles/backend.Dockerfile`: image API Django sans outils lourds.
- `docker/dockerfiles/conversion-worker.Dockerfile`: image lourde avec virt-v2v, qemu, libguestfs, VDDK, Ansible, Terraform.
- `docker/dockerfiles/frontend.Dockerfile`: build Node puis Nginx.
- `docker/entrypoints/*.sh`: migrations DB, collectstatic, preflight, lancement.
- `docker/healthchecks/*.sh`: probes.
- `docker/worker/preflight.sh`: valide binaires, DB, Redis, chemins, espace disque, VDDK.

### `kubernetes/`

Manifests air-gapped avec `imagePullPolicy: Never`.

- `namespace.yaml`: namespace `vmigrate`.
- `secrets.yaml`: secrets runtime.
- `configmap.yaml`: variables non sensibles.
- `mariadb.yaml`: PV/PVC hostPath, Deployment MariaDB, service `database`.
- `redis.yaml`: Redis avec AOF, service interne.
- `backend.yaml`: API Django, PV artefacts, probes, service interne.
- `celery.yaml`: worker privilegie pour qemu/libguestfs et beat non privilegie.
- `frontend.yaml`: Nginx frontend, 2 replicas.
- `ingress.yaml`: expose seulement frontend.

Points a defendre: en production, `hostPath` est un raccourci de labo; utiliser NFS/CSI/StorageClass. Le worker Kubernetes est privilegie, contrairement a la recommandation Docker de ne pas privilegier par defaut; c'est un compromis lie a libguestfs/qemu dans ce manifeste.

### `terraform/`

Provisionnement OpenStack optionnel.

- `provider.tf`: provider OpenStack `~> 2.1`, variables auth.
- `network.tf`: modules base_project, network.
- `security.tf`: module security groups.
- `variables.tf`: auth, region, external network, noms reseau/subnet/router.
- `outputs.tf`: `project_name`, `network_id`, `subnet_id`, `router_id`, `security_group_id`.
- `modules/network/main.tf`: network, subnet, router, interface router.
- `modules/security_groups/main.tf`: security group SSH/ICMP.
- `modules/base_project/main.tf`: expose le nom projet, ne cree pas de projet Keystone.

### `ansible/`

- `playbooks/conversion.yml`: execute `virt-v2v` avec variables libguestfs, installe prerequis sur hote distant si non local, ecrit logs.
- `playbooks/devstack-network.yml`: configure `br-ex`, uplink, route par defaut, service systemd de rebind.
- `inventory/hosts.ini`: cible d'execution.

### `offline/`

Artefacts air-gapped: wheels Python, cache npm, providers Terraform, VDDK, plugin nbdkit, images Docker exportees. Le but est de debrancher le build/deploiement d'Internet.

## 3-4. Banque De Questions Avec Reponses

Format: `R` reponse ideale, `Ev` erreurs a eviter, `Piege` piege probable, `Jury` ce que le jury teste.

### Facile

1. Qu'est-ce que VMigrate ?
   R: Une plateforme web qui orchestre la migration de VMs VMware vers OpenStack: decouverte, conversion disque, validation, upload, deployment et suivi. Ev: dire seulement "convertisseur VMDK". Piege: oublier OpenStack. Jury: vision globale.

2. Quel est le composant principal du backend ?
   R: Django REST Framework dans `backend/`, avec apps `users`, `migrations`, `core`. Ev: Flask/FastAPI. Piege: l'utilisateur a cite FastAPI, mais le projet utilise Django. Jury: connaissance du code.

3. Quel frontend est utilise ?
   R: React/Vite, fichiers dans `frontend/src`, servi par Nginx. Ev: Angular/Vue. Piege: confondre Vite avec serveur prod. Jury: stack.

4. Quel role joue Redis ?
   R: Broker et result backend Celery, configure dans `core/settings.py`, service `redis` en Compose/K8s. Ev: dire base principale. Piege: AOF ne remplace pas DB. Jury: orchestration async.

5. Quelle base est utilisee par defaut en Docker ?
   R: MariaDB 10.11.8 via `docker-compose.yml` et `kubernetes/mariadb.yaml`; SQLite est fallback/test. Ev: repondre PostgreSQL sans nuance. Piege: wheels psycopg2 existent mais pas deploiement principal. Jury: rigueur.

6. Pourquoi Celery ?
   R: Les migrations sont longues et bloquantes; Celery permet jobs asynchrones, retries, queues et workers separes. Ev: "pour aller plus vite" seulement. Piege: API ne doit pas convertir. Jury: architecture.

7. Ou est definie la machine d'etats ?
   R: `MigrationJob.Status` et `TRANSITIONS` dans `backend/migrations/models.py`. Ev: dire frontend. Piege: transitions invalides leves par `InvalidTransitionError`. Jury: modele.

8. Quels sont les statuts principaux ?
   R: PENDING, DISCOVERED, PRECHECK, SNAPSHOT_CREATED, DISK_ANALYZING, CONVERTING, BLOCK_VALIDATING, UPLOADING, DEPLOYED, VERIFIED, FAILED, ROLLED_BACK. Ev: inventer. Piege: DEPLOYED n'est pas final, VERIFIED l'est. Jury: workflow.

9. Ou sont les endpoints API ?
   R: `backend/migrations/urls.py` et `backend/users/urls.py`. Ev: citer seulement frontend. Piege: `/api/` est prefixe dans `core/urls.py`. Jury: routes.

10. Comment l'authentification fonctionne ?
    R: JWT SimpleJWT, login `/api/auth/login`, refresh `/api/auth/refresh`, user role dans token. Ev: sessions Django classiques uniquement. Piege: middleware d'inactivite en plus. Jury: securite.

11. Quels roles existent ?
    R: `SUPER_ADMIN` et `USER` dans `users/models.py`. Ev: admin/operator sans code. Piege: super admin voit plus de donnees. Jury: RBAC.

12. Ou sont stockes les credentials VMware/OpenStack ?
    R: Dans `VmwareEndpointSession` et `OpenstackEndpointSession`, champs password chiffres via `encrypt`. Ev: dire localStorage. Piege: le frontend ne doit pas garder les secrets apres connexion endpoint. Jury: securite.

13. Quel outil convertit les disques ?
    R: `virt-v2v` pour ESXi/VDDK, `qemu-img` pour certains workflows, helpers dans `tasks.py` et `disk_formats.py`. Ev: dire Terraform. Piege: conversion et provisioning sont differents. Jury: virtualisation.

14. Quel format cible OpenStack est vise ?
    R: QCOW2 ou RAW selon execution, QCOW2 principalement, valide avant upload. Ev: VMDK. Piege: Glance accepte plusieurs formats mais code limite qcow2/raw. Jury: stockage.

15. Quels services OpenStack sont utilises ?
    R: Keystone, Glance, Cinder, Nova, Neutron; Horizon n'est pas utilise par le code. Ev: dire Horizon obligatoire. Piege: Horizon est UI seulement. Jury: OpenStack.

16. A quoi sert Glance ?
    R: Stocker les images importees depuis les disques convertis. Ev: boot compute. Piege: ensuite Cinder cree des volumes depuis image. Jury: OpenStack.

17. A quoi sert Cinder ?
    R: Creer et gerer les volumes, boot volume et disques attaches. Ev: reseau. Piege: migration boote depuis volume. Jury: stockage OpenStack.

18. A quoi sert Nova ?
    R: Creer et gerer l'instance OpenStack. Ev: auth. Piege: Nova depend du boot volume et du network. Jury: compute.

19. A quoi sert Neutron ?
    R: Reseaux, subnets, routers, ports, floating IP. Ev: images. Piege: fixed IP doit appartenir au subnet. Jury: reseau.

20. A quoi sert Keystone ?
    R: Authentification et catalogue services OpenStack. Ev: stockage. Piege: expiration token implique reconnexion SDK. Jury: auth cloud.

21. Que fait Terraform dans ce projet ?
    R: Provisionnement optionnel reseau/subnet/router/security group OpenStack, `terraform/`. Ev: conversion VM. Piege: `base_project` n'a pas de resource Keystone. Jury: IaC.

22. Que fait Ansible ?
    R: Optionnel pour executer conversion `virt-v2v` ou configurer DevStack `br-ex`. Ev: orchestration principale. Piege: Celery reste chef d'orchestre. Jury: automatisation.

23. Pourquoi Docker ?
    R: Isoler les runtimes, rendre le deploiement reproductible, separer control plane et worker lourd. Ev: "parce que moderne". Piege: conversion worker reste dependant du noyau Linux. Jury: DevOps.

24. Pourquoi Kubernetes ?
    R: Option de deploiement air-gapped avec probes, services, replicas frontend, secrets/configmaps. Ev: dire obligatoire. Piege: Compose reste chemin dev. Jury: orchestration.

25. Quel fichier Kubernetes expose l'application ?
    R: `kubernetes/ingress.yaml`, seulement frontend. Ev: exposer backend/DB. Piege: Nginx frontend proxy `/api`. Jury: securite reseau.

26. Quel fichier decrit MariaDB K8s ?
    R: `kubernetes/mariadb.yaml`. Ev: `postgres.yaml`. Piege: PV hostPath nomme comme NFS test. Jury: lecture manifeste.

27. Qu'est-ce que `imagePullPolicy: Never` ?
    R: Kubernetes utilise uniquement images deja chargees localement, utile air-gapped. Ev: penser pull DockerHub. Piege: il faut importer sur chaque noeud. Jury: offline.

28. Ou est le fichier actif frontend principal ?
    R: `frontend/src/pages/VMwareInventoryPage.jsx` pour inventaire et lancement migrations. Ev: `App.css`. Piege: logique API dans `src/api`. Jury: UI.

29. Comment le frontend gere les erreurs API ?
    R: `frontend/src/api/client.js` parse JSON, extrait message, tente refresh token sur 401. Ev: silence. Piege: refresh peut echouer. Jury: robustesse.

30. Quel est le but de `DiscoveredVM` ?
    R: Persister l'inventaire VMware: nom, source, endpoint, CPU, RAM, disques, metadata, power state. Ev: le confondre avec job. Piege: unique par name/source/endpoint. Jury: data model.

31. Quel est le but de `MigrationJob` ?
    R: Suivre l'etat d'une migration, metadata, source/destination, progress, timestamps, user. Ev: stocker disque binaire. Piege: metadata JSON porte la spec. Jury: modele metier.

32. Ou sont les logs applicatifs ?
    R: `backend/logs` local, volumes `/app/logs`, logging JSON dans `core/logging.py`; UI logs synthetiques via jobs. Ev: dire uniquement console. Piege: `LogsPage` ne lit pas fichiers bruts. Jury: observabilite.

33. Que se passe-t-il si l'utilisateur se deconnecte pendant une migration ?
    R: La tache Celery continue car elle depend du job en DB, pas de la session HTTP. Ev: dire migration annulee. Piege: session inactivity n'arrete pas worker. Jury: asynchronisme.

34. Comment evite-t-on deux migrations simultanees de la meme VM ?
    R: `create_migrations_from_vmware` cherche des jobs actifs avec meme VM/source/session et les met dans `skipped_jobs`. Ev: dire contrainte DB. Piege: ce n'est pas une contrainte unique. Jury: concurrence.

35. Pourquoi des healthchecks ?
    R: Verifier readiness/liveness backend, Redis, MariaDB, worker, frontend. Ev: surveillance complete. Piege: healthcheck worker ne garantit pas acces VMware/OpenStack sauf preflight strict. Jury: exploitation.

### Moyen

36. Expliquez la creation d'un job depuis le frontend.
    R: `VMwareInventoryPage.jsx` construit payload, `triggerMigrations` appelle `/api/migrations/from-vmware`, serializer valide, vue cree jobs et lance Celery. Ev: ignorer serializer. Piege: un job par VM. Jury: flux complet.

37. Comment les endpoints sont-ils scopes par utilisateur ?
    R: `_session_for_user` filtre par user sauf `SUPER_ADMIN`; serializers utilisent ce helper. Ev: "tout est global". Piege: certaines vues doivent etre auditees. Jury: securite multi-utilisateur.

38. Comment sont valides les fixed IP ?
    R: `CreateMigrationFromVMwareSerializer` appelle `OpenStackClient.validate_fixed_ip` contre le network resolu. Ev: validation regex seulement. Piege: network name ambigu. Jury: reseau.

39. Comment sont valides les floating IP ?
    R: Validation mode, external network id/name, adresse via OpenStackClient. Ev: attribuer arbitrairement. Piege: reseau externe requis. Jury: Neutron.

40. Pourquoi verifier power state ESXi ?
    R: `start_migration` exige VM powered off pour conversion sure, eviter incoherence disque. Ev: snapshot suffit toujours. Piege: snapshots peuvent etre desactives. Jury: integrite.

41. Qu'est-ce que VDDK ?
    R: VMware Virtual Disk Development Kit, utilise avec nbdkit/virt-v2v pour lire des disques VMware. Ev: confondre avec VMDK. Piege: licence/distribution. Jury: VMware.

42. Pourquoi `VMWARE_VDDK_THUMBPRINT` ?
    R: Authentifier le serveur ESXi/vCenter pour le transport VDDK; le code peut resoudre/coloniser SHA1. Ev: ignorer TLS. Piege: SHA256 vs SHA1. Jury: securite transport.

43. Pourquoi `libguestfs` ?
    R: Inspecter/modifier images offline: partitions, filesystem, virt-customize, network remediation. Ev: le confondre avec hyperviseur. Piege: besoin kernel/qemu. Jury: tooling.

44. Pourquoi remediation reseau guest ?
    R: Une VM VMware peut avoir `ens33`/MAC liee; OpenStack expose autre interface. Le service self-heal DHCP evite VM inaccessible. Ev: dire Neutron corrige tout. Piege: cloud-init absent. Jury: migration reelle.

45. Comment le disque systeme est-il choisi ?
    R: Heuristiques dans `tasks.py` et `_guess_system_disk_index`: unit 0, Hard disk 1, inspection system filesystem. Ev: premier disque toujours. Piege: multi-disque. Jury: boot.

46. Pourquoi ne pas fusionner tous les disques ?
    R: Le deployment OpenStack impose correspondance 1-to-1 pour volumes; le code leve erreur si mismatch. Ev: fusion toujours mieux. Piege: boot/attachements/rollback. Jury: conception stockage.

47. Comment est gere le rollback ?
    R: `rollback_migration` nettoie artefacts locaux, images, volumes, serveur via metadata. Ev: rollback magique de la VM source. Piege: snapshot ESXi optionnel/desactive. Jury: resilience.

48. Quels sont les risques du rollback ?
    R: Ressources deja supprimees, volumes attaches, droits insuffisants, metadata incomplete, cleanup partiel. Ev: promettre 100%. Piege: idempotence necessaire. Jury: honnetete.

49. Comment scaler les migrations ?
    R: Ajouter workers Celery, queues separees, limiter concurrency/prefetch, stockage partage performant, capacity CPU/RAM/IO, Redis/DB dimensionnes. Ev: augmenter replicas API seulement. Piege: conversion IO-bound/CPU-bound. Jury: performance.

50. Pourquoi `prefetch_multiplier=1` dans certains workers ?
    R: Eviter qu'un worker reserve trop de jobs longs et affame les autres. Ev: toujours 4. Piege: settings global a 4, compose conversion override a 1. Jury: Celery.

51. Pourquoi `acks_late=True` ?
    R: Ack apres execution pour requeue si worker meurt. Ev: garantit exactement once. Piege: peut reexecuter, il faut idempotence. Jury: fiabilite.

52. Comment les routes API sont protegees ?
    R: DRF `IsAuthenticated` global, `IsSuperAdmin`, controles ownership dans vues/serializers. Ev: CORS = securite. Piege: endpoints publics health/login. Jury: authz.

53. Pourquoi chiffrer les passwords en DB ?
    R: Reduire impact d'une fuite DB; champs `encrypt(...)`. Ev: dire hash car il faut relire le password pour connecter. Piege: cle Django doit etre protegee. Jury: secret management.

54. Pourquoi ne pas hasher les credentials VMware ?
    R: Le systeme doit les reutiliser pour pyVmomi/virt-v2v/OpenStack; hash irreversible impossible. Ev: stocker clair. Piege: encryption at rest != securite complete. Jury: securite.

55. Que contient `conversion_metadata` ?
    R: Source selectionnee, endpoints, projet, requested_spec, plan, validation, execution, openstack resource IDs, logs, rollback. Ev: donnees binaires. Piege: JSONField peut grossir. Jury: modele.

56. Pourquoi JSONField ?
    R: Flexibilite pour metadata variee par workflow sans migrations DB frequentes. Ev: tout mettre en JSON. Piege: requetes/analyse plus difficiles. Jury: design DB.

57. Pourquoi MariaDB plutot que PostgreSQL ?
    R: Le deploiement fourni choisit MariaDB pour simplicite/compatibilite; Django via `DATABASE_URL` peut cibler d'autres DB. PostgreSQL serait meilleur pour JSON/indexing avance. Ev: nier PostgreSQL. Piege: requirements contient psycopg2 wheel offline. Jury: choix technique.

58. Comment diagnostiquer une migration bloquee en PENDING ?
    R: Verifier Redis, worker Celery, queue `migrations`, logs worker, task id, DB job. Ev: redemarrer tout. Piege: control plane peut tourner sans worker. Jury: exploitation.

59. Comment diagnostiquer un echec Glance ?
    R: Logs `ensure_uploaded_image`, endpoint override, token Keystone, format disque, taille, quotas, reachability, status image. Ev: accuser Nova. Piege: DevStack proxy image casse possible. Jury: OpenStack.

60. Comment diagnostiquer Nova qui ne boote pas ?
    R: server status/fault, flavor, boot volume bootable, image metadata, network, quota, scheduler, compute logs. Ev: verifier seulement frontend. Piege: volume peut etre OK mais guest non bootable. Jury: cloud ops.

61. Pourquoi OpenStack deployment est optionnel ?
    R: `ENABLE_OPENSTACK_DEPLOYMENT`; on peut faire dry-run/local storage ou conversion seule. Ev: toujours deployer. Piege: `destination_label=Local storage` si pas OpenStack/use_nfs. Jury: flexibilite.

62. Que signifie dry-run ?
    R: Precheck/plan sans conversion reelle si `ENABLE_REAL_CONVERSION=false`; utile dev/demo. Ev: migration complete. Piege: metadata mode dry-run. Jury: environnement.

63. Pourquoi separer backend et conversion-worker ?
    R: Backend portable et leger; worker porte dependances kernel/qemu/VDDK et risques. Ev: mettre tout dans API. Piege: Docker Desktop non ideal conversion. Jury: architecture.

64. Pourquoi le worker K8s est privilegie ?
    R: Besoins libguestfs/qemu dans ce manifeste; compromis a securiser. Ev: "par habitude". Piege: en Docker doc conseille pas par defaut. Jury: securite K8s.

65. Que changeriez-vous en production K8s ?
    R: CSI/NFS reel, secrets externes, TLS ingress, network policies, registry interne, resource tuning, non-root ou capabilities minimales, monitoring. Ev: garder hostPath. Piege: air-gapped. Jury: maturite.

66. Pourquoi `hostPath` est limite ?
    R: Couple pod a un noeud, faible portabilite, risque securite, pas HA. Ev: dire stockage production. Piege: PV s'appelle NFS mais utilise hostPath. Jury: Kubernetes.

67. Pourquoi `ClusterIP` pour backend/DB/Redis ?
    R: Services internes seulement; exposition externe via frontend ingress. Ev: NodePort partout. Piege: frontend Nginx proxy API. Jury: securite reseau.

68. Comment fonctionne le refresh token ?
    R: `api/client.js` appelle `/api/auth/refresh` sur 401 avec refresh stocke. Ev: refresh infini. Piege: inactivite peut invalider malgre refresh. Jury: auth.

69. Qu'est-ce que `UserSessionActivity` ?
    R: Suivi last_activity par user pour timeout inactivite. Ev: gestion multi-device parfaite. Piege: OneToOne user, pas par device. Jury: limites.

70. Comment le dashboard calcule les stats ?
    R: Endpoint `dashboard` dans `views.py` groupe les jobs par statut/bucket, frontend `DashboardPage.jsx`. Ev: Prometheus. Piege: ce sont stats applicatives. Jury: observabilite.

71. Pourquoi Terraform n'est-il pas utilise pour chaque VM ?
    R: Les VMs migrees dependent d'artefacts dynamiques et workflow imperatif; openstacksdk/Celery gere upload/volumes/boot avec progression. Ev: Terraform inutile. Piege: Terraform gere infra stable, pas pipeline disque. Jury: choix IaC.

72. Pourquoi ne pas utiliser OpenShift ?
    R: Kubernetes standard suffit; OpenShift ajoute contraintes SCC/privileged, registry, routes. Pour worker privilegie, OpenShift demanderait politiques specifiques. Ev: "trop cher" seulement. Piege: conversion worker. Jury: plateforme.

73. Pourquoi ne pas utiliser Terraform pour VMware export ?
    R: Terraform gere etat infra, pas extraction/conversion disque fine. pyVmomi/virt-v2v sont adaptes. Ev: tout faire Terraform. Piege: Terraform state ne doit pas contenir secrets/artefacts. Jury: outil adapte.

74. Pourquoi pas OpenStack Heat ?
    R: Heat pourrait provisionner infra OpenStack mais pas conversion VMware; Terraform plus portable et deja integre. Ev: dire Heat mauvais. Piege: contexte DevStack. Jury: alternatives.

75. Quel est le role de `openstack_deployment.py` ?
    R: Fonctions idempotentes/retry pour image, volume, server, security group, floating IP, delete/verify. Ev: client catalogue simple. Piege: `openstack_client.py` est different. Jury: separation.

76. Quel est le role de `openstack_client.py` ?
    R: Client API pour health/catalogue/projets/reseaux/flavors/images et validations exposees au frontend. Ev: deploiement complet. Piege: deux modules OpenStack. Jury: comprehension code.

77. Comment les flavors sont choisis ?
    R: Soit `flavor_id` demande, soit mapping CPU/RAM via `map_vmware_to_flavor`. Ev: creer flavor automatiquement. Piege: taille insuffisante. Jury: compute.

78. Comment les noms OpenStack sont construits ?
    R: `build_openstack_names(vm_name, job_id)` dans `openstack_deployment.py` pour image/server/volumes. Ev: nom VM brut. Piege: sanitization. Jury: collision/idempotence.

79. Pourquoi des security groups baseline ?
    R: Garantir ICMP/SSH/egress pour accessibilite minimale, configure dans `settings.py`. Ev: ouvrir tout sans mention risque. Piege: 0.0.0.0/0 est permissif. Jury: securite.

80. Comment limiter ce risque ?
    R: Restreindre CIDR admin, parametrer rules JSON, least privilege, audit. Ev: laisser public. Piege: demo vs prod. Jury: durcissement.

81. Comment detecter OS invite ?
    R: `os_profile.py`, metadata/inspection tokens, famille Linux/Windows/unknown. Ev: demander SSH. Piege: detection peut etre low confidence. Jury: migration offline.

82. Que faire si OS unsupported ?
    R: Selon `MIGRATION_FAIL_ON_UNSUPPORTED_OS`, fail ou continuer sans remediation specifique, documenter risque. Ev: supposer Linux. Piege: Windows drivers. Jury: compatibilite.

83. Comment traiter Windows ?
    R: Le code distingue Windows mais remediation reseau Linux ne s'applique pas; besoin drivers VirtIO/cloudbase-init/sysprep eventuellement. Ev: meme chemin Linux. Piege: boot BSOD. Jury: expertise VMware/OpenStack.

84. Quel est le role de snapshots ESXi ?
    R: Point de securite avant migration si active, via `snapshot_manager.py`. Ev: backup complet. Piege: `.env`/config peut les desactiver. Jury: rollback source.

85. Pourquoi `VMWARE_REQUIRE_NO_SNAPSHOTS` ?
    R: Eviter conversion depuis chaine snapshot complexe/incoherente. Ev: snapshots toujours OK. Piege: VMDK delta. Jury: VMware storage.

### Difficile

86. Expliquez la difference ESXi, vCenter, vSphere.
    R: ESXi est hyperviseur; vCenter gere plusieurs ESXi; vSphere est suite/plateforme VMware incluant ESXi/vCenter. Ev: synonymes. Piege: API inventory differente. Jury: VMware.

87. Comment pyVmomi est utilise conceptuellement ?
    R: Connexion API VMware, inventory VM, properties CPU/RAM/disks/NIC/power, snapshots. Ev: conversion disque. Piege: pyVmomi ne convertit pas. Jury: SDK.

88. Pourquoi `virt-v2v -i libvirt -ic esx://...` ?
    R: Permet a virt-v2v de lire source VMware via libvirt/esx et convertir/adaptater guest vers KVM/OpenStack. Ev: simple copy VMDK. Piege: credentials/passfile/VDDK. Jury: conversion.

89. Pourquoi `qemu-img check` ne suffit pas ?
    R: Il valide structure bloc, pas bootabilite, drivers, fstab, reseau, services. Ev: image OK = VM OK. Piege: filesystem check complementaire. Jury: qualite migration.

90. Expliquez block validation vs filesystem validation.
    R: Block: coherence format QCOW2 via `qemu-img`; filesystem: partitions/mounts/usage via libguestfs. Ev: fusionner. Piege: filesystem peut etre non supporte/chiffre. Jury: stockage.

91. Comment gerer disque corrompu apres conversion ?
    R: Stopper deployment, conserver artefacts/logs, `qemu-img check`, reconvertir depuis snapshot/source, verifier datastore, espace disque, checksums. Ev: uploader quand meme. Piege: corruption source vs conversion. Jury: incident.

92. Que faire si token Keystone expire pendant upload ?
    R: OpenStack SDK doit reauth; sinon catch/retry operation, reconnecter `connect_openstack`, eviter uploads gigantesques sans timeout, verifier clock. Ev: relancer toute plateforme. Piege: upload partiel Glance a nettoyer. Jury: cloud auth.

93. Que faire si Neutron network inaccessible ?
    R: Verifier endpoint/catalogue, projet, network_id, subnet, router, DHCP, security group, route/external, quotas, logs Neutron. Ev: accuser guest. Piege: VM active mais pas joignable. Jury: reseau.

94. Glance refuse l'image: causes ?
    R: format invalide, fichier absent, taille/quota, endpoint override, auth, SSL verify, timeout, image status killed, disk_format mismatch. Ev: uniquement credentials. Piege: QCOW2 corrompu. Jury: diagnostic.

95. Nova ne demarre pas: causes ?
    R: flavor, quota, volume non bootable, image invalide, network manquant, scheduler no valid host, compute down, VirtIO drivers. Ev: redemarrer Nova. Piege: erreur dans `server.fault`. Jury: ops.

96. VM importee ne boot pas: causes ?
    R: mauvais disque systeme, bootloader, drivers VirtIO, fstab UUID, initramfs, UEFI/BIOS, Windows HAL/drivers, corruption. Ev: Neutron. Piege: Nova ACTIVE ne veut pas dire OS boot. Jury: virtualisation.

97. Comment choisir entre local storage et NFS ?
    R: Local simple/perf sur un worker; NFS partage artefacts entre pods/workers mais depend montage/perf/locking. Ev: NFS toujours meilleur. Piege: NFS indisponible fallback local dans code. Jury: stockage.

98. Risques NFS pour conversions ?
    R: Latence, throughput, stale handles, permissions UID/GID, espace, locking, single point failure. Ev: ignorer IO. Piege: gros disques. Jury: performance.

99. Comment proteger les secrets Kubernetes ?
    R: Ne pas committer valeurs reelles, external secrets/Vault, RBAC, encryption at rest, rotation, sealed secrets, least privilege. Ev: Opaque = chiffre. Piege: Secret base64 seulement. Jury: K8s sec.

100. Pourquoi `SECRET_KEY` est critique ?
     R: Signe crypto Django/JWT selon config; fuite peut compromettre tokens/chiffrement. Ev: laisser default. Piege: `django_cryptography` depend de settings secrets. Jury: securite.

101. Comment auditer une fuite de credentials endpoint ?
     R: Rotation VMware/OpenStack, invalidate sessions, verifier DB/logs, acces admin, secret key, supprimer endpoint sessions. Ev: seulement changer password app. Piege: logs peuvent contenir commandes. Jury: incident response.

102. Comment eviter fuite password dans `virt-v2v` ?
     R: Passfile temporaire `_write_password_file`, permissions, ne pas logguer commande avec password, cleanup. Ev: password en argument shell. Piege: metadata/logs. Jury: securite process.

103. Quelles limites de performance de `virt-v2v` ?
     R: CPU, IO source/datastore, reseau, compression QCOW2, libguestfs mem, nbdkit threads, absence KVM/TCG. Ev: scaling lineaire. Piege: Docker Desktop. Jury: perf.

104. Pourquoi TCG-safe libguestfs ?
     R: En conteneur sans KVM, utiliser QEMU TCG pour compatibilite, plus lent. Ev: penser acceleration native. Piege: performance degradee. Jury: runtime.

105. Comment ameliorer la performance ?
     R: Worker Linux proche stockage, KVM si possible, disques SSD/NVMe, parallelisme controle, nbdkit threads, NFS performant, upload direct, quotas. Ev: juste augmenter CPU API. Piege: bottleneck IO. Jury: capacity planning.

106. Comment garantir idempotence OpenStack ?
     R: Stocker image_ids/volume_ids/server_id, reutiliser existing ids, noms deterministes, delete idempotent. Ev: creer toujours nouveau. Piege: retry apres crash. Jury: resilience.

107. Pourquoi `acks_late` necessite idempotence ?
     R: Task peut etre rejouee apres crash worker; operations externes doivent retrouver/continuer. Ev: exactly once. Piege: doublons OpenStack. Jury: distributed systems.

108. Comment gerer DB transaction dans `start_migration` ?
     R: Transaction courte avec `select_for_update` pour transition, puis operations longues hors transaction. Ev: garder lock pendant conversion. Piege: blocage DB. Jury: backend.

109. Pourquoi `select_for_update` ?
     R: Eviter transitions concurrentes incoherentes du meme job. Ev: pour performance. Piege: lock seulement en transaction. Jury: concurrence.

110. Quel probleme avec JSONField volumineux ?
     R: taille DB, performance, indexation limitee, payload API lourd, logs tronques. Ev: tout y stocker. Piege: stdout/stderr. Jury: data design.

111. Quelle amelioration DB proposer ?
     R: Tables JobEvent/Artifact/OpenStackResource, logs externes objet/S3/NFS, index status/user/created. Ev: refonte totale sans besoin. Piege: migration progressive. Jury: conception.

112. Comment tester sans VMware/OpenStack reels ?
     R: dry-run, mocks SDK, tests unitaires helpers, fixtures DiscoveredVM, monkeypatch subprocess/OpenStack, shared-images. Ev: tests manuels seulement. Piege: integration a part. Jury: qualite.

113. Que couvrent les tests ?
     R: disk format, qemu wrapper, snapshot policy, runtime virt-v2v/libguestfs, serializers, OpenStack helpers, remediation, OS detection, auth/RBAC/sessions/endpoints. Ev: dire tout. Piege: tests e2e reels limites. Jury: validation.

114. Comment mettre CI/CD ?
     R: lint/test backend, npm build, docker build, scan images, manifests validate, terraform validate, ansible-lint, tests integration optionnels. Ev: deploy direct. Piege: VDDK licence/offline. Jury: DevOps.

115. Pourquoi GitLab ?
     R: Si choisi, pipelines CI/CD, registry interne, variables protegees, runners air-gapped. Dans code pas de `.gitlab-ci.yml`. Ev: pretendre present. Piege: user a cite GitLab mais depot non. Jury: honnetete.

116. Que ferait un pipeline minimal ?
     R: install deps, Django tests, npm ci/build, docker build, trivy/grype, push registry, kubectl apply manuel/approval. Ev: inclure secrets. Piege: imagePullPolicy Never. Jury: delivery.

117. Comment monitorer en production ?
     R: logs centralises, metrics Celery/Redis/DB, job durations, error rates, disk free, queue depth, OpenStack API latency, alerts. Ev: dashboard app seulement. Piege: worker disk. Jury: observabilite.

118. Quels logs chercher lors d'un echec conversion ?
     R: worker logs `/app/logs`, persisted virt-v2v stdout/stderr, conversion error log, job metadata execution. Ev: browser console. Piege: logs peuvent etre tronques. Jury: diagnostic.

119. Pourquoi `OPENSTACK_IMAGE_ENDPOINT_OVERRIDE` ?
     R: Corriger endpoint Glance publie/casse, ex DevStack proxy image, en forcant endpoint reachable. Ev: changer Keystone. Piege: endpoint catalogue vs override. Jury: OpenStack terrain.

120. Comment valider un endpoint OpenStack ?
     R: Auth Keystone, catalogue, list projects/flavors/networks/images selon API. Ev: ping seulement. Piege: projet/domain/interface. Jury: cloud.

121. Comment valider un endpoint VMware ?
     R: Connexion pyVmomi, credentials, host/port/SSL, datacenter si vCenter, inventory accessible. Ev: ping seulement. Piege: cert insecure. Jury: VMware.

122. Pourquoi `insecure=true` est dangereux ?
     R: Desactive verification TLS; risque MITM. Ev: l'utiliser en prod. Piege: besoin lab self-signed. Jury: securite.

123. Comment securiser TLS ?
     R: CA interne, verify true, thumbprints, secrets rotation, endpoint allowlist. Ev: seulement HTTPS. Piege: VDDK thumbprint. Jury: sec reseau.

124. Quelles donnees ne doivent jamais etre logguees ?
     R: passwords, tokens JWT/Keystone, passfiles, secrets env, private keys. Ev: logs debug en prod. Piege: commandes shell. Jury: securite.

125. Comment fonctionne l'air-gapped ?
     R: Images Docker export/import, wheels, npm-cache, provider mirror, VDDK vendor, `imagePullPolicy: Never`. Ev: tirer DockerHub. Piege: chaque noeud doit avoir images. Jury: offline.

### Tres Difficile

126. Comment garantir coherence source si VM reste allumee ?
     R: Idealement shutdown ou snapshot applicatif coherent; sinon risques writes en cours. Le code exige powered off ESXi. Ev: hot copy sans VSS/fsfreeze. Piege: snapshot VMware pas toujours app-consistent. Jury: integrite.

127. Comment gerer une VM avec plusieurs snapshots VMware ?
     R: Consolider snapshots ou refuser selon `VMWARE_REQUIRE_NO_SNAPSHOTS`; comprendre chaines delta. Ev: convertir un delta au hasard. Piege: disque parent manquant. Jury: VMware storage.

128. Comment migrer a chaud ?
     R: Ce projet ne fait pas live migration. Il faudrait replication incrementale, quiesce, cutover, delta sync, compatibilite applicative. Ev: promettre zero downtime. Piege: VMware->OpenStack live non trivial. Jury: limites.

129. Comment reduire downtime ?
     R: Preconvertir copie, sync delta, planifier shutdown courte, automatiser verification, DNS/IP cutover. Ev: conversion pendant fenetre courte uniquement. Piege: coherence DB/app. Jury: architecture migration.

130. Comment gerer MAC/IP statiques dans guest ?
     R: Remediation supprime bindings HWADDR/UUID, DHCP self-heal; pour IP statique il faut mapping/config guest specifique. Ev: DHCP regle tout. Piege: apps liees a IP/MAC. Jury: reseau guest.

131. Pourquoi cloud-init peut poser probleme ?
     R: Il peut reecrire le reseau en conflit; option pour desactiver rendu network. Ev: cloud-init toujours present. Piege: images migrees ne sont pas cloud images. Jury: guest OS.

132. Comment gerer UEFI vs BIOS ?
     R: Identifier firmware source, config Nova image properties/hypervisor, bootloader/ESP. Le code ne semble pas traiter explicitement tout UEFI. Ev: supposer BIOS. Piege: disque GPT/EFI. Jury: boot.

133. Comment gerer VirtIO drivers Windows ?
     R: Injecter drivers VirtIO, ajuster boot controller, possible sysprep/cloudbase-init; tester avant cutover. Ev: traiter comme Linux. Piege: inaccessible ou BSOD. Jury: expertise migration.

134. Comment gerer VMware Tools ?
     R: virt-v2v peut remplacer/adapter certains agents; retirer dependances VMware, installer cloud/virtio agents. Ev: laisser VMware Tools. Piege: services inutiles/erreurs. Jury: conversion.

135. Comment verifier que la VM cible est fonctionnelle applicativement ?
     R: Au-dela de Nova ACTIVE: ping/SSH, service checks, application health, logs guest, tests metier. Ev: ACTIVE=OK. Piege: firewall guest. Jury: SRE.

136. Comment eviter que Redis devienne SPOF ?
     R: Redis HA/Sentinel/cluster ou broker robuste, persistence, monitoring; accepter que DB garde etat durable. Ev: AOF suffit. Piege: tasks en vol. Jury: resilience.

137. Comment eviter DB SPOF ?
     R: MariaDB HA/replication/backup/PITR, storage fiable, migrations controlees. Ev: PVC unique. Piege: metadata critique. Jury: production.

138. Comment gerer quotas OpenStack ?
     R: Precheck quotas images, volumes, cores, RAM, instances, floating IP; fail early. Ev: decouvrir a la fin. Piege: multi-projet. Jury: cloud ops.

139. Comment traiter une migration partiellement reussie apres crash worker ?
     R: Reprise idempotente via metadata resource IDs, verifier statuts OpenStack, continuer ou rollback. Ev: supprimer aveuglement. Piege: task replay. Jury: distributed recovery.

140. Comment securiser worker privilegie ?
     R: Noeuds dedies, network policies, image signee, capabilities minimales, AppArmor/SELinux si possible, secrets limites, audit, pas d'acces Internet. Ev: privileged partout. Piege: compromise worker. Jury: K8s sec.

141. Pourquoi backend ne doit pas monter `/boot` et `/lib/modules` ?
     R: Pas besoin; ca augmente surface d'attaque et couple au host. Seul worker conversion peut en avoir besoin. Ev: simplifier par mounts globaux. Piege: doc container architecture. Jury: isolation.

142. Comment dimensionner worker ?
     R: Par taille disque, debit datastore/NFS/Glance, CPU, mem libguestfs, concurrency faible par worker pour gros jobs, tests de charge. Ev: 200 jobs sur un node. Piege: settings cible 200 mais ressources reelles. Jury: capacity.

143. Comment prioriser jobs ?
     R: Celery queues/priorities, separation discovery/provisioning/migrations, prefetch controle. Ev: FIFO unique. Piege: Redis priority support limite selon transport. Jury: Celery.

144. Quelle limite de `max_retries=0` sur `start_migration` ?
     R: Pas de retry Celery global; retries geres par helpers internes/OpenStack. Un echec marque job failed/rollback. Ev: croire auto retry. Piege: decorator explicite. Jury: lecture code.

145. Comment reexecuter une migration echouee ?
     R: Creer nouveau job ou endpoint/action dedie; eviter transition depuis FAILED sauf rollback. Nettoyer ressources, corriger cause. Ev: repasser status manuellement. Piege: state machine. Jury: operations.

146. Pourquoi `FAILED -> ROLLED_BACK` seulement ?
     R: Conserver historique d'echec, rollback est action corrective; pas de retour arbitraire vers running. Ev: reset status. Piege: audit. Jury: modele.

147. Comment integrer notifications ?
     R: Job events + WebSocket/SSE/email, Celery signals, table notifications. Ev: polling seulement pour toujours. Piege: frontend actuellement poll/refresh. Jury: amelioration.

148. Comment remplacer polling ?
     R: Django Channels/WebSocket ou SSE, Redis pub/sub, events DB. Ev: frontend setInterval partout. Piege: auth WebSocket. Jury: UX/scale.

149. Comment proteger API contre abus ?
     R: throttling DRF, quotas user, validation taille payload, RBAC, audit logs, rate limit ingress. Ev: JWT suffit. Piege: lancement jobs couteux. Jury: securite applicative.

150. Comment eviter SSRF via endpoints fournis ?
     R: Allowlist reseaux/hosts, validation DNS/IP, blocage metadata IP, permissions, audit. Ev: accepter n'importe quelle URL OpenStack/host. Piege: backend/worker connectent a host utilisateur. Jury: securite avancee.

151. Comment eviter command injection ?
     R: subprocess avec listes d'args, sanitization, pas shell sauf Ansible controle, passfile, noms sanitizes. Ev: concatener input. Piege: `virt_v2v_command` dans Ansible shell. Jury: secure coding.

152. Comment gerer chemins fichiers non fiables ?
     R: base dirs controles, sanitization noms, Path resolve, verifier existence/permissions, pas traversal. Ev: accepter path frontend. Piege: Workstation paths. Jury: securite filesystem.

153. Que faire si `qemu-img` manque ?
     R: preflight worker echoue ou conversion fail claire; verifier image worker, PATH, packages. Ev: installer dans backend. Piege: backend Docker ne l'a pas. Jury: runtime.

154. Que faire si VDDK plugin manque ?
     R: preflight, verifier `/opt/vmware-vddk`, nbdkit plugin path, LD_LIBRARY_PATH, licence, offline vendor. Ev: pip install. Piege: non redistribuable. Jury: VMware tooling.

155. Comment traiter certificats VMware self-signed en prod ?
     R: Import CA ou thumbprint valide; eviter `insecure`. Ev: toujours false verify. Piege: lab vs prod. Jury: securite.

156. Pourquoi Horizon n'est pas integre ?
     R: Horizon est UI OpenStack; VMigrate parle aux API via SDK, ce qui est automatisable. Ev: dire OpenStack sans Horizon impossible. Piege: user liste Horizon. Jury: OpenStack.

157. Comment migrer reseau VMware portgroup vers Neutron ?
     R: Mapping portgroup -> network/subnet Neutron via spec frontend, fixed IP optional; automatiser mapping futur. Ev: conversion automatique complete. Piege: VLAN, DHCP, security groups. Jury: reseau.

158. Comment gerer stockage thin/thick ?
     R: Inspection sparse, qemu/virt-v2v output, volumes Cinder size derivee; attention expansion. Ev: taille fichier = taille disque. Piege: virtual_size vs size. Jury: stockage.

159. Pourquoi `derived_volume_size_gb` ?
     R: Calculer taille volume depuis min_disk, image size, virtual_size pour Cinder. Ev: toujours 1Gi. Piege: image sparse. Jury: OpenStack storage.

160. Comment prouver la valeur metier ?
     R: Reduction operations manuelles, audit, rollback, reproductibilite, interface unique, baisse erreurs, migration industrialisee. Ev: parler uniquement techno. Piege: soutenance PFE demande besoin. Jury: impact.

## 5. Simulation Question Par Question

Regle de simulation dans le chat:

1. Je pose une question.
2. Tu reponds sans consulter la reponse ideale.
3. Je corrige, je note sur 20, je dis ce qui manque.
4. Si la reponse est faible, je repose ou je reformule.
5. Je change de role jury selon le theme: architecte Cloud, DevOps, OpenStack, VMware, backend, Docker/Kubernetes, professeur.

Bareme rapide:

- 18-20: reponse exacte, fichier cite, limites mentionnees.
- 14-17: bonne comprehension, quelques details manquent.
- 10-13: idee generale mais pas assez code/projet.
- 6-9: reponse vague ou partiellement fausse.
- 0-5: contresens technique ou hors projet.

## 6. Questions Par Domaine A Reviser

VMware/vCenter/ESXi/vSphere: ESXi hyperviseur, vCenter management central, vSphere suite, pyVmomi inventory, snapshots, datastore, VMDK, VDDK, power state, portgroups.

OpenStack: Keystone auth/catalogue, Glance images, Cinder volumes, Nova instances, Neutron networks/ports/floating IP/security groups, Horizon UI non utilisee.

Docker/Kubernetes: separation backend/worker, Compose dev, air-gapped K8s, probes, secrets/configmaps, hostPath limites, worker privilegie.

Python/Django/DRF/Celery: serializers, views, models, JWT, middleware, tasks async, transactions courtes, idempotence.

REST API: routes dans `backend/migrations/urls.py` et `backend/users/urls.py`, frontend clients `frontend/src/api`.

Base de donnees: MariaDB principal, SQLite test/fallback, JSONField, indexes status/user, encryption credentials.

Nginx: sert SPA et proxy API/admin.

Git/GitLab/CI-CD: pas de pipeline present; proposer tests, build, scan, registry, deploy avec approvals.

Linux/SSH/Ansible: worker Linux, host executor SSH optionnel, playbooks conversion/devstack network.

Virtualisation/cloud: format disque, drivers, boot mode, network mapping, volumes, quotas.

Securite: secrets, TLS, RBAC, session inactivity, logs, command injection, SSRF, worker privilegie.

Monitoring/logs: logs JSON, worker logs, queue depth, job duration, OpenStack API latency, disk free.

## 7. Questions "Pourquoi"

- Pourquoi Django/DRF ? Parce que le projet a besoin de modeles, admin, auth, serializers, REST et integration Celery mature.
- Pourquoi Celery ? Pour isoler les taches longues et permettre retries/queues/workers.
- Pourquoi Docker ? Reproductibilite et separation runtime.
- Pourquoi Kubernetes ? Packaging air-gapped, orchestration, probes, services, scaling frontend/worker.
- Pourquoi MariaDB ? Choix de deploiement fourni; Django reste configurable via `DATABASE_URL`.
- Pourquoi pas PostgreSQL ? PostgreSQL serait pertinent pour JSON/indexing, mais pas le choix actuel du manifeste.
- Pourquoi pas Terraform partout ? La migration est un workflow imperatif avec artefacts dynamiques; Terraform reste pour infra stable.
- Pourquoi pas OpenShift ? Kubernetes suffit; OpenShift demanderait SCC adaptees au worker privilegie.
- Pourquoi pas migration live ? Complexite replication delta/coherence applicative, hors scope actuel.

## 8. Bugs Simules Et Diagnostics

Migration echoue:
Verifier status job, `conversion_metadata`, logs worker, Redis, DB, source VM powered off, espace disque, outils conversion, OpenStack quotas. Ne pas supprimer les artefacts avant diagnostic.

Token Keystone expire:
Verifier clock, credentials, domain/project, SDK reauth, retries, endpoint override; nettoyer image partielle si upload interrompu.

Neutron inaccessible:
Verifier endpoint catalogue, project scope, network/subnet/router/DHCP/security group, fixed IP, port, floating IP, routes.

Glance refuse image:
Verifier format qcow2/raw, `qemu-img info/check`, taille/quota, endpoint image, SSL, timeout, status killed.

Nova ne demarre pas:
Verifier server fault, flavor, quota, boot volume, image properties, network, compute logs, scheduler.

VM importee ne boot pas:
Verifier disque systeme choisi, bootloader, UEFI/BIOS, VirtIO drivers, fstab UUID, initramfs, OS profile.

Disque corrompu:
Stopper deployment, comparer source/target, reconvertir, verifier datastore, VDDK, espace, checksum, logs qemu/virt-v2v.

NFS indisponible:
Verifier mount, permissions, `NFS_ENABLED`, `NFS_PATH`, espace, fallback local, logs storage.

Worker mort:
Verifier Celery, OOMKilled, probes, logs, resource limits, Redis requeue, idempotence OpenStack.

Secrets invalides:
Tester endpoints, verifier Secret/ConfigMap, rotation, redemarrage pods, logs sans exposer valeurs.

## 9. Limites Et Ameliorations

Limites:

- Pas de migration live/zero downtime.
- Windows necessite gestion VirtIO/cloudbase-init plus avancee.
- `hostPath` K8s non ideal production.
- Worker K8s privilegie a durcir.
- JSONField peut grossir.
- Pas de pipeline CI/CD visible dans le depot.
- Pas de monitoring Prometheus/Grafana integre.
- Logs UI synthetiques, pas lecteur centralise.
- Terraform ne cree pas reellement un projet Keystone dans `base_project`.
- La migration applicative apres boot n'est pas validee automatiquement.

Ameliorations:

- Event sourcing JobEvent/Artifact/OpenStackResource.
- WebSocket/SSE pour progression temps reel.
- Precheck quotas OpenStack.
- Mapping reseau VMware portgroup vers Neutron.
- Support Windows mature.
- Stockage objet pour artefacts/logs.
- Vault/External Secrets.
- NetworkPolicies et TLS ingress.
- CI/CD complet avec scans.
- Tests integration sur lab VMware/OpenStack.
- HA Redis/MariaDB.

## 10. Simulation 1 Heure

Plan propose:

- 0-5 min: pitch projet, besoin, architecture.
- 5-15 min: workflow migration et state machine.
- 15-25 min: VMware, VDDK, conversion, stockage.
- 25-35 min: OpenStack Glance/Cinder/Nova/Neutron.
- 35-45 min: Docker/Kubernetes, air-gapped, securite.
- 45-55 min: bugs, performance, limites, ameliorations.
- 55-60 min: synthese, note, points forts/faibles.

La simulation commence dans le chat par une question simple, puis le jury devient plus agressif selon tes reponses.
