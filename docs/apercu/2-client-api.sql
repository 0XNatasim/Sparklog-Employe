-- À coller dans l'éditeur SQL (mode d'emploi, étape 8). Crée la « clé » que Sparklog-Gestion (ici : votre test avec curl) utilisera pour parler au côté 1.
-- Le SECRET (colonne `secret`, commence par skc_) n'est affiché QU'UNE FOIS : copiez-le tout de suite dans un endroit privé (pas dans ce dépôt, pas dans une conversation).
select id, secret from public.sync_create_client('apercu');
