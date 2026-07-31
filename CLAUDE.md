# fedora-audiophile-setup — notes pour agents

## Versioning — règle stricte

Ce dépôt est épinglé par des projets externes (notamment Tune OS, l'image appliance de Bertrand Clech/renesenses). Les tags de release (`vMAJOR.MINOR.PATCH`, semver) sont des tags **annotés** (`git tag -a`).

**Un tag publié ne doit jamais être réécrit, supprimé, ni redéplacé sur un autre commit** — ni par un agent, ni manuellement. Si une release taguée s'avère fautive, publier un nouveau patch (`vX.Y.Z+1`), jamais retaguer l'existant. Voir le README, section "Versioning".

## Repo sœur

Ce dépôt (x86 PC) a un pendant ARM64/Raspberry Pi : [fedora-rpi-audiophile-setup](https://github.com/cometdom/fedora-rpi-audiophile-setup), même structure modulaire, mêmes garanties de versioning.
