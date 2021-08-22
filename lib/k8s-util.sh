# kubectl utility functions

pvc_fix_perms() {
    ## Fix file permissions in a PV volume
    ## args: NAMESPACE PVC_CLAIM USER_ID CHOWN_OCTAL
    ## eg: pvc_fix_perms harbor-system data-harbor-redis-0 999 0700
    kubectl run -n $1 -i --rm perms-fix --image=alpine:3 --restart=Never \
      --overrides="{\"apiVersion\": \"v1\", \"kind\": \"Pod\", \"metadata\": {\"name\": \"perms-fix\"}, \"spec\": {\"containers\": [{\"name\": \"perms-fix\", \"image\": \"alpine:3\", \"command\": [\"/bin/sh\",\"-c\"], \"args\": [\"chown $3 /data; chmod $4 /data\"], \"volumeMounts\": [{\"name\": \"data\", \"mountPath\": \"/data\"}]}], \"volumes\": [{\"name\": \"data\", \"persistentVolumeClaim\": {\"claimName\": \"$2\"}}]}}"
}

run_with_pvc() {
    ## Run an interactive container, mounting a PV volume to /data
    ## args: NAMESPACE IMAGE PVC_CLAIM SCRIPT
    kubectl run -n $1 --rm -i --tty tmp-pvc-run --image=$2 --restart=Never \
      --overrides="{\"apiVersion\": \"v1\", \"kind\": \"Pod\", \"metadata\": {\"name\": \"tmp-pvc-run\"}, \"spec\": {\"containers\": [{\"name\": \"tmp-pvc-run\", \"image\": \"$2\", \"stdin\": true, \"tty\": true, \"command\": [\"/bin/sh\",\"-c\"], \"args\": [\"$4\"], \"volumeMounts\": [{\"name\": \"data\", \"mountPath\": \"/data\"}]}], \"volumes\": [{\"name\": \"data\", \"persistentVolumeClaim\": {\"claimName\": \"$3\"}}]}}"
}
