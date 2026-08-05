#!/bin/bash
# Ricifra i manifest di k8s/site/ e rimuove il lock file.
export SOPS_AGE_RECIPIENTS=$(<public-age-keys.txt)
echo ${SOPS_AGE_RECIPIENTS}

SITEFILES="secrets secrets-pg storage ingress"

for SITEFILE in $SITEFILES; do
  FNAME="./k8s/site/$SITEFILE.yaml"
  if [ -f $FNAME ]; then
    echo "Encrypting $FNAME ..."
    sops --encrypt --in-place --age ${SOPS_AGE_RECIPIENTS} $FNAME
  fi
done;

# rm lock file
rm decrypted
