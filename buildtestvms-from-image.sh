#!/bin/bash

# Instruct Foreman to rebuild the test VMs
#
# e.g ${WORKSPACE}/scripts/buildtestvms.sh 'test'
#
# this will tell Foreman to rebuild all machines in hostgroup TESTVM_HOSTGROUP

# Load common parameter variables
. $(dirname "${0}")/common.sh

if [[ -z ${PUSH_USER} ]] || [[ -z ${SATELLITE} ]]  || [[ -z ${RSA_ID} ]] \
   || [[ -z ${ORG} ]] || [[ -z ${TESTVM_HOSTCOLLECTION} ]]
then
    err "Environment variable PUSH_USER, SATELLITE, RSA_ID, ORG " \
        "or TESTVM_HOSTCOLLECTION not set or not found."
    exit ${WORKSPACE_ERR}
fi

get_test_vm_list # populate TEST_VM_LIST

# TODO: Error out if no test VM's are available.
if [ $(echo ${#TEST_VM_LIST[@]}) -eq 0 ]; then
  err "No test VMs configured in Satellite"
fi

# rebuild test VMs
# while testing, I disabled _Destroy associated VM on host delete_

### also disabled for now
exit 1

# for each host; dump Org, Loc and HG in a file, process that

for I in "${TEST_VM_LIST[@]}"
do
    SUT_TMP_INFOFILE=$(mktemp)
    ssh -q -l ${PUSH_USER} -i ${RSA_ID} ${SATELLITE} \
        "hammer host info --id $I" | awk -F '[[:space:]][[:space:]]+' '$1~/^(Name|Organi[sz]ation|Host Group|Location)/ {print $1,$2}' > ${SUT_TMP_INFOFILE}
    SUT_NAME=$(awk -F ': ' '$1~/^Name/ {print $2}' ${SUT_TMP_INFOFILE})
    SUT_ORG=$(awk -F ': ' '$1~/^Organi[sz]ation/ {print $2}' ${SUT_TMP_INFOFILE})
    SUT_HG_TITLE=$(awk -F ': ' '$1~/^Host Group/ {print $2}' ${SUT_TMP_INFOFILE})
    SUT_LOC=$(awk -F ': ' '$1~/^Location/ {print $2}' ${SUT_TMP_INFOFILE})
    rm -I ${SUT_TMP_INFOFILE}

    inform "Deleting VM ID $I"
    ssh -q -l ${PUSH_USER} -i ${RSA_ID} ${SATELLITE} \
        "hammer host delete --id $I"

    inform "Recreating VM ID $I"
    ssh -q -l ${PUSH_USER} -i ${RSA_ID} ${SATELLITE} \
        "hammer host create \
         --name \"${SUT_NAME}\" \
         --organization \"${SUT_ORG}\" \
         --location \"${SUT_LOC}\" \
         --hostgroup-title \"${SUT_HG_TITLE}\" \
         --provision-method image \
         --enabled true \
         --managed true \
         --compute-attributes=\"start=1\""

# do use 
# --hostgroup-title "Test Servers/Jenkins pipeline SOE-CI/image-based"
# because that I can get from a hammer host info output
# hammer host info --name sattestclient05.sattest.pcfe.net|grep -e "^Organi[sz]ation" -e "^Host Group" -e "^Location"
hammer host create \
--name "kvm-test2" \
--organization "Sat Test" \
--location "Bergmannstraße" \
--hostgroup "image-based" \
--provision-method image \
--enabled true \
--managed true \
--compute-attributes="start=1"



done


# we need to wait until all the test machines have been rebuilt by foreman
# this check was previously only in pushtests, but when using pipelines 
# it's more sensible to wait here while the machines are in build mode
# the ping and ssh checks must remain in pushtests.sh
# as a pupet only build will not call this script

declare -A vmcopy # declare an associative array to copy our VM array into
for I in "${TEST_VM_LIST[@]}"; do vmcopy[$I]=$I; done

# the below test from the kickstart based installs will also work for image based installs.
# the stayus of Build: still changes
#[root@satellite ~]# hammer host info --name kvm-test2.sattest.pcfe.net | grep -e "Managed" -e "Enabled" -e "Build"
#Managed:                  yes
#    Build Status:  Pending installation
#    Build:                  yes
#    Enabled:    yes
#[root@satellite ~]# hammer host info --name kvm-test2.sattest.pcfe.net | grep -e "Managed" -e "Enabled" -e "Build"
#Managed:                  yes
#    Build Status:  Installed
#    Build:                  no
#    Enabled:    yes

# But potentially also check for
#  Build Status:  Pending installation
# changing to
#  Build Status:  Installed
WAIT=0
while [[ ${#vmcopy[@]} -gt 0 ]]
do
    inform "Waiting 1 minute"
    sleep 60
    ((WAIT+=60))
    for I in "${vmcopy[@]}"
    do
        inform "Checking if host $I is in build mode."
        status=$(ssh -q -l ${PUSH_USER} -i ${RSA_ID} ${SATELLITE} \
            "hammer host info --name $I | \
            grep -e \"Managed.*yes\" -e \"Enabled.*yes\" -e \"Build.*no\" \
                | wc -l")
        # Check if status is OK, then the SUT will have left build mode
        if [[ ${status} == 3 ]]
        then
            tell "host $I no longer in build mode."
            unset vmcopy[$I]
            # reboot the box here so that new kernel is active
            # this is only necessay on image based installs
            tell "rebooting host $I since it applied errata as part of cloud-init and we want latest kernel and glibc active"
            hammer host reboot --name $I
        else
            tell "host $I is still in build mode."
        fi
    done
    if [[ ${WAIT} -gt 6000 ]]
    then
        err "At least one host still in build mode after 6000 seconds. Exiting."
        exit 1
    fi
done
