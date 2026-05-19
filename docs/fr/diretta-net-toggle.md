<!-- Translated from docs/en/diretta-net-toggle.md — last sync: 2026-05-19 -->

# Bascule NIC Diretta — pont ⇄ indépendant (systemd-networkd)

Un petit outil compagnon ([`scripts/diretta-net-toggle.sh`](../../scripts/diretta-net-toggle.sh)) pour faire basculer un hôte Diretta à deux cartes réseau entre son fonctionnement **indépendant** normal et un mode **pont** temporaire.

Pourquoi : en fonctionnement normal, la cible Diretta est au bout d'une carte dédiée en point-à-point (`enp4s0`) et **n'est pas** sur votre LAN ; vous ne pouvez donc pas l'atteindre depuis un navigateur/une appli pour vérifier ou appliquer une **mise à jour de firmware de la cible** sans la rebrancher physiquement sur un switch. Le mode pont place les deux cartes sur le même segment L2 : la cible obtient une adresse DHCP du LAN et devient joignable — sans recâblage. Vous rebasculez ensuite pour l'écoute.

> systemd-networkd uniquement (module 03 du wizard → **S**). Une variante NetworkManager pourra venir plus tard.

## Les deux modes

```
indépendant  (normal, audiophile)
  routeur/LAN ──┤ enp5s0 (DHCP)                 hôte
                │ enp4s0 (link-local, L2) ── cible Diretta (PAS sur le LAN)

pont  (transitoire, vérif firmware — MTU forcé à 1500)
  routeur/LAN ──┤ enp5s0 ┐
                │         ├─ diretta-br0 (DHCP)  hôte
                │ enp4s0 ┘            └──────── cible Diretta (désormais SUR le LAN,
                                                 obtient une adresse DHCP du LAN)
```

## Pré-requis

- L'hôte utilise **systemd-networkd** (pas NetworkManager).
- Lancer en **root**.
- Une **session SSH passant par le LAN tombe brièvement** pendant une bascule (l'IP migre entre la carte LAN et le pont le temps du redémarrage de `systemd-networkd`). Le pont épingle l'adresse MAC de la carte LAN, donc le bail DHCP — et donc l'**IP — reste la même** ; il suffit de se reconnecter sur la même adresse après quelques secondes. Une console locale reste appréciable mais n'est plus strictement nécessaire.

## Utilisation

```bash
sudo ./scripts/diretta-net-toggle.sh status        # lecture seule : mode courant + état des ifaces
sudo ./scripts/diretta-net-toggle.sh bridge        # → cible joignable depuis le LAN
sudo ./scripts/diretta-net-toggle.sh independent   # → retour au mode écoute normal
```

`bridge` et `independent` demandent une confirmation et avertissent avant de redémarrer `systemd-networkd`. `status` ne modifie rien.

### Détection des interfaces

Aucun nom de carte codé en dur — le script résout les cartes LAN et Diretta dans cet ordre de priorité :

1. **Surcharge par variables d'env** (expert) : `DIRETTA_LAN_IFACE` / `DIRETTA_TARGET_IFACE`.
   ```bash
   sudo DIRETTA_LAN_IFACE=enpXsY DIRETTA_TARGET_IFACE=enxAABBCC ./scripts/diretta-net-toggle.sh status
   ```
2. **Mapping enregistré** : `/etc/diretta-net-toggle.conf` (écrit la première fois que les rôles sont résolus).
3. **Auto-détection** : sur un hôte à 2 cartes, LAN = l'interface qui porte la route par défaut ; Diretta = l'autre ethernet physique.
4. **Interactif** : si toujours ambigu (0/1 ou 3+ cartes, ou pas de route par défaut), il liste les cartes ethernet physiques (avec l'état du lien et l'IPv4) et vous demande de choisir.

Le couple résolu est **persisté** dans le fichier d'état. C'est important car en mode `bridge` la route par défaut est sur le pont, pas sur une carte physique — l'auto-détection seule ne pourrait pas les remapper, mais le fichier enregistré le fait. Les noms du type `enx00e04c…` (RTL8156 USB) sont gérés sans souci. Pour forcer une nouvelle détection, supprimez le fichier d'état :

```bash
sudo rm /etc/diretta-net-toggle.conf
```

## Procédure de vérification firmware

1. `sudo ./scripts/diretta-net-toggle.sh bridge` — confirmez les invites.
2. Reconnectez-vous si votre SSH est tombé. Trouvez la nouvelle adresse LAN de la cible : la page des baux DHCP de votre routeur, ou `ip neigh show dev diretta-br0`, ou un rapide `nmap -sn` sur le sous-réseau de votre LAN.
3. Ouvrez l'interface web de la cible / lancez son updater depuis n'importe quelle machine du LAN ; vérifiez/appliquez la mise à jour firmware.
4. `sudo ./scripts/diretta-net-toggle.sh independent` — retour au lien dédié.
5. Redémarrez (recommandé) pour que le `.link` udev jumbo de la carte Diretta se réapplique et que le service renderer démarre proprement.

## Ce que l'outil écrit

Tous les fichiers portent une première ligne `# Managed by diretta-net-toggle` ; changer de mode supprime les fichiers de l'outil correspondant à l'autre mode et écrit le nouveau jeu sous `/etc/systemd/network/` (`<LAN>` / `<DIR>` sont les noms de cartes résolus) :

- **indépendant** : `10-<LAN>.network` (DHCP) + `10-<DIR>.network` (link-local, `ConfigureWithoutCarrier=yes`).
- **pont** : `15-diretta-br0.netdev` (`Kind=bridge`, **`MACAddress=` épinglée sur la carte LAN**) + `10-<LAN>.network`/`10-<DIR>.network` (`Bridge=`, `MTUBytes=1500`) + `20-diretta-br0.network` (DHCP, `MTUBytes=1500`).

Plus le mapping d'interfaces dans `/etc/diretta-net-toggle.conf` (voir *Détection des interfaces* ci-dessus).

## Remarques importantes

- **IP stable (épinglage de la MAC du pont)** : un pont Linux adopte par défaut la plus petite MAC parmi ses ports — souvent celle de la carte Diretta — si bien que le serveur DHCP attribuerait au pont une IP *différente* de celle qu'avait la carte LAN, vous forçant à vous reconnecter sur une nouvelle adresse (et encore une fois au défaire du pont). Cet outil épingle la MAC de `diretta-br0` sur celle de la carte LAN, donc le bail DHCP et l'**IP restent les mêmes** entre `indépendant ⇄ pont`. Si la MAC de la carte LAN ne peut pas être lue, il avertit et retombe sur le comportement par défaut (l'IP peut changer).
- **MTU** : le mode pont est forcé à **1500** pour la compatibilité LAN (une trame jumbo sur un segment LAN en 1500 casse tout). Le drop-in `.link` jumbo de la carte Diretta (posé par `install-drup`/`install-slim2diretta`) n'est surchargé que pendant le pont ; `independent` le laisse se réappliquer — redémarrez pour en être sûr.
- **Conflit avec le module 03 du wizard** : `network-stack → S` écrit `10-<iface>.network` tagué `# Generated by fedora-audiophile-setup`. Cet outil écrit les mêmes noms de fichiers avec son propre tag et **prend la main** sur la config de ces deux cartes. S'il trouve un fichier non géré là, il vous avertit. `independent` rétablit une config Diretta fonctionnelle équivalente à celle du wizard.
- **Transitoire par conception** : n'écoutez pas en mode pont (pas de jumbo, cible exposée sur le LAN, chemin L2 supplémentaire). C'est pour la vérif firmware, puis on rebascule.

## Dépannage

- *Réseau / SSH perdu après une bascule* : attendez ~10 s, reconnectez-vous sur la même IP. Depuis la console : `networkctl status`, `ip -br addr`. Relancez la sous-commande voulue.
- *La cible n'a pas eu d'adresse LAN en mode pont* : elle est peut-être éteinte, ou sa carte est montée après le pont — éteignez/rallumez la cible, puis `networkctl reconfigure diretta-br0` (ou relancez simplement `bridge`).
- *Mauvaises cartes détectées* : supprimez `/etc/diretta-net-toggle.conf` et relancez (il re-détecte), ou épinglez-les explicitement avec `DIRETTA_LAN_IFACE=… DIRETTA_TARGET_IFACE=… sudo …` (cela réécrit aussi le fichier d'état).
- *Tout annuler* : `sudo ./scripts/diretta-net-toggle.sh independent` est l'état « off » normal. Pour rendre la main au wizard, relancez `sudo ./setup.sh --only network-stack` après avoir supprimé les fichiers tagués de l'outil (et `/etc/diretta-net-toggle.conf`).
