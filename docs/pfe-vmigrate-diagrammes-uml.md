# Diagrammes UML et architecture - VMigrate

Ce document fournit les diagrammes PlantUML exploitables dans le chapitre 3 du rapport PFE. Les elements retenus proviennent du code et des documents `README.md`, `docs/architecture.md` et `docs/container-architecture.md`.

## Figure 3.1 - Diagramme de cas d'utilisation de la plateforme VMigrate

### Objectif du diagramme

Presenter les fonctionnalites visibles par l'administrateur dans la plateforme VMigrate : administration, gestion des endpoints, decouverte, orchestration de migration et supervision.

### Code PlantUML

```plantuml
@startuml
title Diagramme de cas d'utilisation de la plateforme VMigrate
left to right direction

actor "Administrateur" as Admin

rectangle "Plateforme VMigrate" {
  usecase "S'authentifier" as UCAuth
  usecase "Gerer les utilisateurs" as UCUsers
  usecase "Ajouter un endpoint VMware" as UCVmwareEndpoint
  usecase "Ajouter un endpoint OpenStack" as UCOpenStackEndpoint
  usecase "Decouvrir les machines virtuelles" as UCDiscover
  usecase "Consulter l'inventaire" as UCInventory
  usecase "Configurer une migration" as UCConfigure
  usecase "Lancer une migration" as UCStart
  usecase "Suivre l'etat des migrations" as UCTrack
  usecase "Consulter les journaux" as UCLogs
  usecase "Gerer les parametres systeme" as UCSettings
  usecase "Consulter le tableau de bord" as UCDashboard
}

Admin --> UCAuth
Admin --> UCUsers
Admin --> UCVmwareEndpoint
Admin --> UCOpenStackEndpoint
Admin --> UCDiscover
Admin --> UCInventory
Admin --> UCConfigure
Admin --> UCStart
Admin --> UCTrack
Admin --> UCLogs
Admin --> UCSettings
Admin --> UCDashboard

UCDiscover ..> UCVmwareEndpoint : <<include>>
UCInventory ..> UCDiscover : <<extend>>
UCConfigure ..> UCInventory : <<include>>
UCConfigure ..> UCOpenStackEndpoint : <<include>>
UCStart ..> UCConfigure : <<include>>
UCTrack ..> UCStart : <<extend>>
UCLogs ..> UCTrack : <<extend>>
UCDashboard ..> UCTrack : <<include>>
UCUsers ..> UCAuth : <<include>>
UCSettings ..> UCAuth : <<include>>
@enduml
```

### Description detaillee

Le diagramme represente l'administrateur comme acteur principal du systeme. Les cas d'utilisation correspondent aux modules reels exposes par le frontend React et l'API Django REST : authentification JWT, gestion des utilisateurs, endpoints VMware et OpenStack, inventaire VMware, creation de jobs de migration, suivi des statuts, journaux synthetiques et tableau de bord. Les relations `include` indiquent des dependances obligatoires, par exemple la configuration d'une migration necessite un inventaire et un endpoint OpenStack lorsque le deploiement cible est demande. Les relations `extend` indiquent des fonctions de supervision disponibles apres creation ou execution d'une migration.

### Emplacement recommande

Chapitre 3, section "Expression des besoins fonctionnels" ou "Cas d'utilisation de la solution".

### Suggestions d'amelioration UML

Ajouter ulterieurement un acteur "Operateur" si le rapport distingue les roles `SUPER_ADMIN` et `USER` implementes dans le modele `User`.

## Figure 3.2 - Workflow de migration VMware vers OpenStack

### Objectif du diagramme

Decrire le processus metier complet d'une migration depuis la validation de la demande jusqu'a la verification finale ou au rollback.

### Code PlantUML

```plantuml
@startuml
title Workflow de migration VMware vers OpenStack

start
:Authentification de l'administrateur;
:Selection de la VM decouverte;
:Validation des sessions VMware et OpenStack;

if (Donnees valides ?) then (oui)
  :Creation du MigrationJob;
  :Envoi de la tache Celery via Redis;
else (non)
  :Retourner erreurs de validation;
  stop
endif

partition "Celery Worker" {
  :Precheck de conversion;
  if (Precheck OK ?) then (oui)
    if (Snapshot ESXi active ?) then (oui)
      :Creation snapshot ESXi;
      if (Snapshot OK ?) then (oui)
      else (non)
        :Marquer FAILED;
        :Rollback;
        stop
      endif
    else (non)
      :Snapshot ignore;
    endif

    :Analyse disque;
    :Conversion virt-v2v / qemu-img;
    if (Conversion OK ?) then (oui)
      :Remediation reseau guest si applicable;
      :Validation bloc QCOW2;
      :Validation systeme de fichiers;
    else (non)
      :Ecrire journal d'erreur persistant;
      :Marquer FAILED;
      :Rollback artefacts locaux et ressources OpenStack;
      stop
    endif

    if (Validations OK ?) then (oui)
      :Upload des images vers Glance;
      :Creation des volumes Cinder;
      :Creation instance Nova depuis volume;
      :Attachement des volumes additionnels;
      :Verification serveur, volumes et reseau;
    else (non)
      :Marquer FAILED;
      :Rollback artefacts locaux;
      stop
    endif

    if (Verification finale OK ?) then (oui)
      :Statut VERIFIED;
      stop
    else (non)
      :Statut FAILED;
      :Rollback serveur, volumes et images;
      :Statut ROLLED_BACK;
      stop
    endif
  else (non)
    :Marquer FAILED;
    :Rollback si ressources creees;
    stop
  endif
}
@enduml
```

### Description detaillee

L'activite suit l'implementation de `create_migrations_from_vmware` puis `start_migration`. L'API valide la selection VM, les sessions endpoint, les doublons et les parametres OpenStack avant de creer un `MigrationJob`. L'execution longue est ensuite confiee a Celery via Redis. Le worker effectue les etapes de precheck, snapshot optionnel, analyse disque, conversion, validation bloc/filesystem, upload OpenStack, creation Cinder/Nova et verification finale. Les branches d'erreur conduisent au statut `FAILED` et declenchent `rollback_migration` lorsque le rollback est active.

### Emplacement recommande

Chapitre 3, section "Processus metier de migration" ou "Workflow fonctionnel".

### Suggestions d'amelioration UML

Separarer ce diagramme en deux swimlanes supplementaires "API Django" et "OpenStack" si une granularite organisationnelle plus forte est souhaitee.

## Figure 3.3 - Sequence d'execution d'une migration VMigrate

### Objectif du diagramme

Montrer les interactions temporelles entre l'administrateur, le frontend, l'API, Redis, Celery, VMware, la chaine de conversion et OpenStack.

### Code PlantUML

```plantuml
@startuml
title Sequence d'execution d'une migration VMigrate
autonumber

actor "Administrateur" as Admin
participant "React Frontend" as Frontend
participant "Django API" as API
database "MariaDB" as DB
queue "Redis" as Redis
participant "Celery Worker" as Worker
participant "VMware ESXi" as VMware
participant "virt-v2v / qemu-img" as V2V
participant "OpenStack" as OpenStack

Admin -> Frontend : Selectionner VM et parametres cible
Frontend -> API : POST /api/migrations/from-vmware
API -> DB : Valider sessions et DiscoveredVM
API -> DB : Creer MigrationJob(PENDING)
API -> Redis : Publier start_migration(job_id)
API --> Frontend : 201 Created(created_jobs)

Worker -> Redis : Consommer tache start_migration
Worker -> DB : Verrouiller job et transition PENDING -> DISCOVERED -> PRECHECK
Worker -> VMware : Lire metadonnees VM et inventaire disque
VMware --> Worker : Disques, power_state, datastore
Worker -> DB : Enregistrer precheck

alt Snapshot active
  Worker -> VMware : Creer snapshot de securite
  VMware --> Worker : Snapshot cree
  Worker -> DB : Transition SNAPSHOT_CREATED
else Snapshot desactive
  Worker -> DB : Transition directe DISK_ANALYZING
end

Worker -> DB : Enregistrer analyse disque
Worker -> V2V : Convertir VMDK vers QCOW2
V2V --> Worker : Artefacts QCOW2 et rapports
Worker -> V2V : Validation bloc et filesystem
V2V --> Worker : Resultats de validation
Worker -> DB : Transition BLOCK_VALIDATING -> UPLOADING

Worker -> OpenStack : Upload image Glance
OpenStack --> Worker : image_id
Worker -> OpenStack : Creer volume Cinder depuis image
OpenStack --> Worker : volume_id
Worker -> OpenStack : Creer serveur Nova depuis volume
OpenStack --> Worker : server_id
Worker -> OpenStack : Verifier serveur, volumes, reseau
OpenStack --> Worker : Etat ACTIVE et volumes in-use
Worker -> DB : Transition DEPLOYED -> VERIFIED

loop Suivi periodique
  Frontend -> API : GET /api/migrations/{id}
  API -> DB : Lire statut et metadata
  API --> Frontend : Statut, progression, details
end

alt Erreur pendant l'execution
  Worker -> DB : Marquer FAILED et journaliser l'erreur
  Worker -> Redis : Publier rollback_migration(job_id)
  Worker -> OpenStack : Supprimer serveur, volumes, images si crees
  Worker -> DB : Transition FAILED -> ROLLED_BACK
end
@enduml
```

### Description detaillee

La sequence formalise l'execution asynchrone. Le frontend ne lance pas directement les operations d'infrastructure ; il cree une demande via l'API. L'API persiste le job en base MariaDB et publie la tache Celery dans Redis. Le worker consomme la tache, execute les operations VMware et conversion, puis deploie dans OpenStack. Le retour de statut est indirect : le worker met a jour la base et le frontend interroge l'API pour afficher l'etat courant.

### Emplacement recommande

Chapitre 3, section "Architecture dynamique" ou "Scenario nominal de migration".

### Suggestions d'amelioration UML

Ajouter des messages detailles vers Glance, Cinder, Nova et Neutron dans une version annexe si le rapport doit documenter OpenStack service par service.

## Figure 3.4 - Architecture logicielle de VMigrate

### Objectif du diagramme

Representer les composants logiciels majeurs, leurs interfaces et leurs dependances internes.

### Code PlantUML

```plantuml
@startuml
title Architecture logicielle de VMigrate
skinparam componentStyle rectangle

package "Presentation" {
  [Frontend React] as Frontend
}

package "Backend applicatif" {
  [Backend Django REST] as Backend
  [API Authentification JWT] as Auth
  [API Migrations] as MigrationAPI
  [API Endpoints VMware/OpenStack] as EndpointAPI
}

package "Persistance et asynchrone" {
  database "MariaDB" as MariaDB
  queue "Redis" as Redis
  [Celery] as Celery
}

package "Plan de conversion" {
  [virt-v2v] as VirtV2V
  [qemu-img] as QemuImg
  [Ansible] as Ansible
}

package "Provisioning cible" {
  [OpenStack SDK] as OpenStackSDK
  [Terraform] as Terraform
}

package "Connecteurs source" {
  [VMware SDK] as VMwareSDK
}

Frontend --> Backend : HTTPS/REST /api
Backend --> Auth
Backend --> MigrationAPI
Backend --> EndpointAPI
Backend --> MariaDB : ORM Django
Backend --> Redis : publication taches Celery
Celery --> Redis : consommation files
Celery --> MariaDB : lecture/ecriture etats
Celery --> VMwareSDK : decouverte ESXi/vCenter
Celery --> VirtV2V : conversion VMDK -> QCOW2
Celery --> QemuImg : conversion et validation bloc
Celery --> Ansible : conversion optionnelle
Celery --> OpenStackSDK : Glance, Cinder, Nova, Neutron
Celery --> Terraform : provisioning OpenStack optionnel
EndpointAPI --> VMwareSDK : test connexion VMware
EndpointAPI --> OpenStackSDK : test connexion OpenStack
@enduml
```

### Description detaillee

Le frontend React consomme l'API REST Django. Le backend porte les endpoints d'authentification, de gestion d'infrastructure, de migration et de supervision. MariaDB stocke les utilisateurs, sessions endpoint, VMs decouvertes, jobs et executions de provisioning. Redis sert de broker et backend de resultats Celery. Les workers Celery integrent les bibliotheques et outils d'infrastructure : VMware SDK pour la decouverte, virt-v2v/qemu-img/libguestfs pour la conversion, OpenStack SDK pour Glance/Cinder/Nova/Neutron, Ansible et Terraform pour les chemins d'automatisation presents dans le projet.

### Emplacement recommande

Chapitre 3, section "Architecture logicielle de la solution".

### Suggestions d'amelioration UML

Transformer les API internes en interfaces UML explicites si le rapport detaille les contrats REST endpoint par endpoint.

## Figure 3.5 - Architecture de deploiement de VMigrate

### Objectif du diagramme

Decrire le deploiement conteneurise reel selon `container-architecture.md`, avec un control plane portable et un conversion plane specialise.

### Code PlantUML

```plantuml
@startuml
title Architecture de deploiement de VMigrate

node "Poste utilisateur" {
  artifact "Navigateur Web" as Browser
}

node "Docker Host - Control Plane" {
  node "frontend container\nNginx + React build" as FrontendContainer
  node "backend container\nDjango + Gunicorn" as BackendContainer
  database "db container\nMariaDB 10.11.8" as DBContainer
  queue "redis container\nRedis 7.2.5" as RedisContainer
  node "beat container\nCelery Beat" as BeatContainer
}

node "Linux Host - Conversion Plane" {
  node "conversion-worker container\nCelery Worker" as WorkerContainer
  artifact "virt-v2v / qemu-img / libguestfs" as ConversionTools
  artifact "Ansible / Terraform" as AutomationTools
}

cloud "VMware ESXi / vCenter" as VMware
cloud "OpenStack Cloud\nGlance, Cinder, Nova, Neutron" as OpenStack

Browser --> FrontendContainer : HTTP
FrontendContainer --> BackendContainer : reverse proxy /api, /admin
BackendContainer --> DBContainer : mysql://db:3306
BackendContainer --> RedisContainer : redis://redis:6379/0
BeatContainer --> RedisContainer : scheduled tasks
WorkerContainer --> RedisContainer : Celery queues
WorkerContainer --> DBContainer : state updates
WorkerContainer --> BackendContainer : optional HTTP callbacks
WorkerContainer --> ConversionTools : local execution
WorkerContainer --> AutomationTools : optional automation
WorkerContainer --> VMware : discovery and disk access
WorkerContainer --> OpenStack : image upload and server deployment
@enduml
```

### Description detaillee

Le deploiement separe explicitement les responsabilites. Le control plane contient le frontend, le backend, Redis, MariaDB et Celery Beat ; il est concu pour rester portable et ne contient pas les dependances lourdes de virtualisation. Le conversion plane est un worker Linux dedie, rattache au meme reseau Docker `vm-migrator-control`, qui consomme les taches Redis et met a jour MariaDB. Cette separation isole les contraintes virt-v2v, qemu-img, libguestfs, VDDK, Ansible et Terraform du plan applicatif.

### Emplacement recommande

Chapitre 3, section "Architecture de deploiement conteneurisee".

### Suggestions d'amelioration UML

Ajouter les volumes Docker nommes si le rapport consacre une sous-section a la persistance et aux artefacts de conversion.

## Figure 3.6 - Modele conceptuel des donnees VMigrate

### Objectif du diagramme

Representer les classes metier persistantes principales et leurs relations selon les modeles Django reels.

### Code PlantUML

```plantuml
@startuml
title Modele conceptuel des donnees VMigrate
hide circle
skinparam classAttributeIconSize 0

class User {
  +id: Integer
  +username: String
  +email: Email
  +role: Role
  +created_at: DateTime
}

class MigrationJob {
  +id: Integer
  +vm_name: String
  +source: String
  +destination: String
  +status: Status
  +conversion_metadata: JSON
  +progress_percent: Integer
  +current_step: String
  +progress_details: JSON
  +created_at: DateTime
  +updated_at: DateTime
  +started_at: DateTime
  +completed_at: DateTime
  +transition(new_status)
  +update_progress(percent, step, details)
}

class DiscoveredVM {
  +id: Integer
  +name: String
  +source: Source
  +cpu: Integer
  +ram: Integer
  +disks: JSON
  +metadata: JSON
  +power_state: String
  +last_seen: DateTime
}

class VmwareEndpointSession {
  +id: Integer
  +label: String
  +host: String
  +port: Integer
  +username: String
  +password: EncryptedString
  +insecure: Boolean
  +datacenter: String
  +last_test_status: TestStatus
  +last_test_message: Text
  +last_test_at: DateTime
  +expires_at: DateTime
}

class OpenstackEndpointSession {
  +id: Integer
  +label: String
  +auth_url: String
  +username: String
  +password: EncryptedString
  +project_name: String
  +user_domain_name: String
  +project_domain_name: String
  +region_name: String
  +interface: String
  +identity_api_version: String
  +verify: Boolean
  +image_endpoint_override: String
  +last_test_status: TestStatus
}

class OpenStackProvisioningRun {
  +id: Integer
  +task_id: String
  +state: String
  +message: Text
  +created_at: DateTime
  +updated_at: DateTime
}

enum Role {
  SUPER_ADMIN
  USER
}

enum Status {
  PENDING
  DISCOVERED
  PRECHECK
  SNAPSHOT_CREATED
  DISK_ANALYZING
  CONVERTING
  BLOCK_VALIDATING
  UPLOADING
  DEPLOYED
  VERIFIED
  FAILED
  ROLLED_BACK
}

User "1" --> "0..*" MigrationJob : cree
User "1" --> "0..*" VmwareEndpointSession : possede
User "1" --> "0..*" OpenstackEndpointSession : possede
User "1" --> "0..*" OpenStackProvisioningRun : lance
VmwareEndpointSession "0..1" --> "0..*" DiscoveredVM : decouvre
MigrationJob "0..*" ..> DiscoveredVM : reference par metadata\n(name, source, endpoint)
MigrationJob "0..*" ..> VmwareEndpointSession : reference selected_vmware_endpoint_session_id
MigrationJob "0..*" ..> OpenstackEndpointSession : reference selected_openstack_endpoint_session_id
User ..> Role
MigrationJob ..> Status
@enduml
```

### Description detaillee

Le modele met en evidence les entites persistantes principales. `User` porte le role applicatif. `VmwareEndpointSession` et `OpenstackEndpointSession` conservent les parametres de connexion avec mots de passe chiffres. `DiscoveredVM` represente l'inventaire VMware decouvert. `MigrationJob` constitue l'agregat principal de suivi : statut, progression, timestamps et metadonnees de conversion. Les relations directes presentes dans les modeles sont des cles etrangeres depuis les sessions et les jobs vers l'utilisateur ; certaines associations de `MigrationJob` vers les endpoints et la VM decouverte sont stockees dans `conversion_metadata`, ce qui est represente par des dependances UML.

### Emplacement recommande

Chapitre 3, section "Modele conceptuel et persistance".

### Suggestions d'amelioration UML

Normaliser ulterieurement les references stockees dans `conversion_metadata` en cles etrangeres explicites afin de renforcer les cardinalites relationnelles.

## Figure 3.7 - Cycle de vie d'une migration

### Objectif du diagramme

Formaliser la machine d'etats du `MigrationJob` telle qu'elle est implementee dans le modele Django.

### Code PlantUML

```plantuml
@startuml
title Cycle de vie d'une migration

[*] --> PENDING : creation job
PENDING --> DISCOVERED : start_migration
PENDING --> FAILED : erreur initiale

DISCOVERED --> PRECHECK : validation inventaire
DISCOVERED --> CONVERTING : reprise directe autorisee
DISCOVERED --> FAILED : erreur decouverte

PRECHECK --> SNAPSHOT_CREATED : snapshot active
PRECHECK --> DISK_ANALYZING : snapshot desactive
PRECHECK --> FAILED : precheck invalide

SNAPSHOT_CREATED --> DISK_ANALYZING : snapshot cree ou ignore
SNAPSHOT_CREATED --> FAILED : echec snapshot

DISK_ANALYZING --> CONVERTING : plan disque etabli
DISK_ANALYZING --> FAILED : echec analyse

CONVERTING --> BLOCK_VALIDATING : conversion terminee
CONVERTING --> UPLOADING : validation bloc ignoree ou deja faite
CONVERTING --> FAILED : echec conversion

BLOCK_VALIDATING --> UPLOADING : validations OK
BLOCK_VALIDATING --> FAILED : validation KO

UPLOADING --> DEPLOYED : ressources OpenStack creees
UPLOADING --> FAILED : echec upload/deploiement

DEPLOYED --> VERIFIED : verification finale OK
DEPLOYED --> ROLLED_BACK : rollback manuel
DEPLOYED --> FAILED : verification KO

FAILED --> ROLLED_BACK : rollback_migration

VERIFIED --> [*]
ROLLED_BACK --> [*]
@enduml
```

### Description detaillee

Cette machine d'etats suit la constante `TRANSITIONS` du modele `MigrationJob`. Le statut initial est `PENDING`. Les transitions nominales vont jusqu'a `VERIFIED`. Chaque etape critique peut basculer en `FAILED`. Le rollback est autorise depuis `FAILED` et depuis `DEPLOYED`. Les etats `VERIFIED` et `ROLLED_BACK` sont terminaux. La transition `DISCOVERED -> CONVERTING` et `CONVERTING -> UPLOADING` sont conservees car elles existent dans le code, meme si le chemin nominal passe par `PRECHECK` et `BLOCK_VALIDATING`.

### Emplacement recommande

Chapitre 3, section "Gestion des etats et fiabilite du workflow".

### Suggestions d'amelioration UML

Ajouter des gardes UML explicites, par exemple `[ENABLE_ESXI_MIGRATION_SNAPSHOT=false]`, si le rapport veut relier les transitions aux variables d'environnement.

## Figure 3.8 - Architecture conteneurisee de VMigrate

### Objectif du diagramme

Mettre en evidence la separation entre control plane et conversion plane, ainsi que les canaux Redis et MariaDB.

### Code PlantUML

```plantuml
@startuml
title Architecture conteneurisee de VMigrate
skinparam componentStyle rectangle

package "Control Plane portable" {
  [Frontend\nNginx + React] as CPFrontend
  [Backend\nDjango REST] as CPBackend
  database "MariaDB\nEtat durable" as CPDB
  queue "Redis\nBroker Celery" as CPRedis
  [Celery Beat\nScheduler] as CPBeat
}

package "Conversion Plane Linux" {
  [Conversion Worker\nCelery] as ConvWorker
  [virt-v2v] as VirtV2V
  [qemu-img] as Qemu
  [libguestfs / nbdkit / VDDK] as Guestfs
  [Ansible] as Ansible
  [Terraform] as Terraform
  folder "Artefacts QCOW2\nBackups et logs" as Artifacts
}

cloud "VMware ESXi / vCenter" as VMware
cloud "OpenStack APIs" as OpenStack

CPFrontend --> CPBackend : REST via /api
CPBackend --> CPDB : ORM Django
CPBackend --> CPRedis : publication taches
CPBeat --> CPRedis : taches planifiees
ConvWorker --> CPRedis : consommation queues\nmigrations, discovery, provisioning
ConvWorker --> CPDB : statuts, metadata, progression
ConvWorker --> VMware : inventaire et acces disques
ConvWorker --> VirtV2V : conversion principale
ConvWorker --> Qemu : conversion/validation bloc
ConvWorker --> Guestfs : inspection et remediation guest
ConvWorker --> Ansible : chemin de conversion optionnel
ConvWorker --> Terraform : provisioning optionnel
ConvWorker --> Artifacts : images, backups, error_logs
ConvWorker --> OpenStack : Glance, Cinder, Nova, Neutron
@enduml
```

### Description detaillee

Le control plane regroupe uniquement les services portables : livraison web, API, base de donnees, broker et planification. Le conversion plane concentre les operations dependantes de Linux et de la virtualisation : virt-v2v, qemu-img, libguestfs, nbdkit/VDDK, Ansible, Terraform et stockage des artefacts. Redis assure le decouplage temporel entre API et worker ; MariaDB assure la coherence durable du suivi.

### Emplacement recommande

Chapitre 3, section "Architecture Docker et orchestration".

### Suggestions d'amelioration UML

Ajouter un stereotype `<<external network: vm-migrator-control>>` si le diagramme est integre a une sous-section Docker Compose detaillee.

## Figure 3.9 - Flux de donnees au sein de VMigrate

### Objectif du diagramme

Decrire la circulation des donnees depuis l'utilisateur jusqu'au retour de statut, en passant par l'API, Redis, le worker, VMware, la conversion et OpenStack.

### Code PlantUML

```plantuml
@startuml
title Flux de donnees au sein de VMigrate
left to right direction

actor "Utilisateur" as User
rectangle "Frontend React" as Frontend
rectangle "Django API" as API
database "MariaDB" as DB
queue "Redis" as Redis
rectangle "Celery Worker" as Worker
cloud "VMware" as VMware
rectangle "Conversion\nvirt-v2v / qemu-img" as Conversion
cloud "OpenStack" as OpenStack
rectangle "Retour de statut" as Status

User --> Frontend : Identifiants, endpoints,\nselection VM, options
Frontend --> API : Requetes REST JSON
API --> DB : Users, sessions,\nDiscoveredVM, MigrationJob
API --> Redis : Messages de taches
Redis --> Worker : start_migration,\ndiscover_vmware_vms,\nrollback_migration
Worker --> VMware : Inventaire, snapshots,\nlecture disques
VMware --> Worker : Metadata VM et chemins VMDK
Worker --> Conversion : Plan, VMDK, options
Conversion --> Worker : QCOW2, rapports,\nerreurs eventuelles
Worker --> OpenStack : Images, volumes,\nserveur, reseau
OpenStack --> Worker : IDs et etats ressources
Worker --> DB : Statut, progression,\nconversion_metadata
Frontend --> API : Polling dashboard/jobs/logs
API --> DB : Lecture etat courant
DB --> API : Donnees de suivi
API --> Frontend : JSON statut et details
Frontend --> Status : Affichage dashboard,\njobs et journaux
Status --> User : Etat de migration
@enduml
```

### Description detaillee

Le flux montre que VMigrate n'utilise pas une execution synchrone bloquante. Les donnees fonctionnelles entrent par le frontend, sont validees et persistees par l'API, puis transformees en messages Celery. Le worker produit les artefacts de conversion et les ressources OpenStack, puis ecrit le statut dans MariaDB. Le frontend obtient le retour via l'API en consultant les jobs, le dashboard ou les journaux.

### Emplacement recommande

Chapitre 3, section "Flux de donnees et communication inter-composants".

### Suggestions d'amelioration UML

Completer avec un DFD de niveau 1 si le rapport doit distinguer donnees d'identification, metadonnees VM, artefacts disque et donnees de supervision.

