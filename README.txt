KOVOIT V2 — SUPABASE
=====================

Cette version est une base réelle pour Kovoit. Elle n'utilise plus localStorage pour les données métier.

FICHIERS
- index.html : application Web Kovoit
- supabase-config.js : URL + clé publishable de ton projet
- supabase_schema.sql : tables, fonctions et règles RLS
- manifest.json : métadonnées PWA

INSTALLATION
1. Crée un projet Supabase.
2. Ouvre SQL Editor et exécute entièrement supabase_schema.sql.
3. Dans Authentication > Providers, active Email.
4. Crée un utilisateur de test dans Authentication > Users.
5. Dans SQL Editor, rends ton premier administrateur, par exemple :
   update public.profiles set role='admin' where email='admin@entreprise.fr';
6. La configuration Supabase est déjà renseignée dans supabase-config.js pour le projet Kovoit.
   Le domaine email est volontairement laissé vide pour permettre le premier test.
   Pour limiter l'accès aux salariés, remplace companyEmailDomain par le vrai domaine email de l'entreprise.
7. Héberge le dossier sur un site HTTPS (ou teste avec un serveur local).

IMPORTANT
- N'utilise jamais une clé secret/service_role dans le navigateur.
- La restriction du domaine email dans l'interface est une première barrière. Pour une vraie production, privilégie les invitations/approbations des salariés ou une règle côté serveur/Auth.
- Les réservations passent par la fonction book_trip() pour éviter les sur-réservations concurrentes.

FONCTIONS V2
- Connexion Supabase Auth
- Profils employés
- Recherche de trajets
- Création de trajets
- Réservation sécurisée
- Annulation de réservation
- Annulation de trajet conducteur
- Messagerie réelle entre utilisateurs
- Tableau de bord administrateur réel
- RLS PostgreSQL

La V2 est une base Web/PWA. Pour iPhone/Android natifs, l'étape suivante est de porter cette interface vers Expo/React Native tout en conservant Supabase comme backend.
