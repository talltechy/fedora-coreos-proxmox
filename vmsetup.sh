#!/bin/bash

# Uncomment the following line to enable debug mode
# set -x
set -e

# =============================================================================================
# global vars

# Force English messages
export LANG=C
export LC_ALL=C

# Function to display help information
show_help() {
    echo "Usage: vmsetup.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --update-snippets          Update the hook script and template snippets and exit."
    echo "  --help                     Display this help message and exit."
    echo "  --update-script            Update the script from the git repository and reload."
    echo ""
    echo "This script sets up a Fedora CoreOS VM template in a Proxmox VE environment."
    echo "It checks for required commands, downloads the CoreOS image, and configures the VM."
    exec "$0" "$@"
}

# Function to display the main menu
main_menu() {
    echo "Select an option:"
    echo "1. Run the script"
    echo "2. Update the hook script and template snippets"
    echo "3. Display help information"
    echo "4. Update the script from the git repository and reload"
    echo "5. Exit"
    read -p "Enter your choice [1-5]: " choice

    case $choice in
        1)
            echo "Running the script..."
            ;;
        2)
            UPDATE_SNIPPETS_ONLY=true
            ;;
        3)
            show_help
            exit 0
            ;;
        4)
            echo "Updating the script from the git repository..."
            git pull
            echo "Reloading the script..."
            exec "$0" "$@"
            ;;
        5)
            echo "Exiting."
            exit 0
            ;;
        *)
            echo "Invalid choice. Exiting."
            exit 1
            ;;
    esac
}

# Function to check for script updates
check_for_updates() {
    local current_version latest_version
    current_version=$(git rev-parse HEAD)
    latest_version=$(git ls-remote origin -h refs/heads/main | awk '{print $1}')

    if [ "$current_version" != "$latest_version" ]; then
        echo "================================================================================"
        echo "                                UPDATE AVAILABLE                                "
        echo "================================================================================"
        echo "A new version of this script is available."
        echo "Current version: $current_version"
        echo "Latest version:  $latest_version"
        echo "Please update the script by selecting the update option or manually by running: git pull"
        echo "================================================================================"
    fi
}

# Call the update check function
check_for_updates

# Call the main menu function
main_menu

# Check for the --update-snippets or --update-script flag
for arg in "$@"; do
    case $arg in
        --update-snippets)
        UPDATE_SNIPPETS_ONLY=true
        shift
        ;;
        --help)
        show_help
        exit 0
        ;;
        --update-script)
        echo "Updating the script from the git repository..."
        git pull
        echo "Reloading the script..."
        exec "$0" "$@"
        ;;
    esac
done

# Source the template.conf file
if [ -f template.conf ]; then
    source template.conf
else
    echo "Configuration file template.conf not found!"
    exit 1
fi

# Check if running in Proxmox VE environment
if ! command -v pvesh &> /dev/null; then
    echo "This script must be run in a Proxmox VE environment."
    exit 1
fi

# Verify required commands are available
missing_cmds=()
for cmd in \
    curl \
    jq \
    wget \
    xz \
    qm \
    sha256sum; do
        if ! command -v $cmd &> /dev/null; then
            missing_cmds+=($cmd)
        fi
done

# Check if there are any missing commands and prompt the user to install them
if [ ${#missing_cmds[@]} -ne 0 ]; then
        echo "The following required commands are missing: ${missing_cmds[@]}"
        read -p "Do you want to install them? (y/n) " choice
        if [[ $choice == [Yy]* ]]; then
                if command -v apt-get &> /dev/null; then
                        sudo apt-get update && sudo apt-get install -y ${missing_cmds[@]}
                elif command -v yum &> /dev/null; then
                        sudo yum install -y ${missing_cmds[@]}
                elif command -v dnf &> /dev/null; then
                        sudo dnf install -y ${missing_cmds[@]}
                else
                        echo "Package manager not found. Please install the missing commands manually."
                        exit 1
                fi
        else
                echo "The following commands are required: ${missing_cmds[@]}. Exiting."
                exit 1
        fi
fi

# Function to find the next available VMID starting from 900
find_next_available_vmid() {
    local vmid=900
    local vmids=$(pvesh get /cluster/resources --type vm --output-format json | jq -r '.[].vmid')
    while echo "$vmids" | grep -q "^$vmid$"; do
        vmid=$((vmid + 1))
    done
    echo $vmid
}

# Set TEMPLATE_VMID to the next available VMID
TEMPLATE_VMID=$(find_next_available_vmid)

# template vm vars
TEMPLATE_VMSTORAGE=${TEMPLATEVMSTORAGE}
SNIPPET_STORAGE=${SNIPPETSTORAGE}
VMDISK_OPTIONS=${VMDISKOPTIONS}
TEMPLATE_IGNITION=${TEMPLATEIGNITION:-fcos-base-tmplt.yaml}
# Default to stable, alternatively override with environment variable with either stable, testing, or next
STREAMS=${STREAMS_V:-stable}
ARCHITECTURES=${ARCHITECTURES_V:-x86_64}
PLATFORM=${PLATFORM_V:-qemu}
BASEURL=${BASE_URL:-https://builds.coreos.fedoraproject.org}
# URL to fetch the stable release JSON
RELEASE_JSON=${BASEURL}/streams/${STREAMS}.json
# Fetch the JSON data and extract the stable release number using jq
VERSION=$(curl -s $RELEASE_JSON | jq -r ".architectures.${ARCHITECTURES}.artifacts.${PLATFORM}.release")
if [ $? -ne 0 ]; then
    echo "Failed to fetch the stable release JSON from $RELEASE_JSON"
    exit 1
fi
# This section checks if all necessary environment variables are set to avoid runtime errors.
required_vars=(TEMPLATE_VMID TEMPLATE_VMSTORAGE SNIPPET_STORAGE STREAMS TEMPLATE_NAME VMDISK_OPTIONS)
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "Environment variable $var is required but not set."
        exit 1
    fi
done

# =============================================================================================
# main()

# pve storage exist ?
echo -n "Check if vm storage ${TEMPLATE_VMSTORAGE} exists... "
pvesh get /storage/${TEMPLATE_VMSTORAGE} --noborder --noheader &> /dev/null || {
        echo -e "[failed]"
        exit 1
}
echo "[ok]"

# pve storage snippet ok ?
echo -n "Check if snippet storage ${SNIPPET_STORAGE} exists... "
if ! snippet_storage_info=$(pvesh get /storage/${SNIPPET_STORAGE} --noborder --noheader 2>/dev/null); then
    echo -e "[failed]"
    exit 1
fi
echo "[ok]"
pvesh get /storage/${SNIPPET_STORAGE} --noborder --noheader | grep -q snippets || {
        echo "You must activate content snippet on storage: ${SNIPPET_STORAGE}"
    exit 1
}

# copy files
echo "Copy hook-script and ignition config to snippet storage..."
snippet_storage="$(pvesh get /storage/${SNIPPET_STORAGE} --output-format json | jq -r '.path')"
cp -av ${TEMPLATE_IGNITION} hook-fcos.sh ${snippet_storage}/snippets
sed -e "/^COREOS_TMPLT/ c\COREOS_TMPLT=${snippet_storage}/snippets/${TEMPLATE_IGNITION}" -i ${snippet_storage}/snippets/hook-fcos.sh
chmod 755 ${snippet_storage}/snippets/hook-fcos.sh

# Reload script after updating snippets
if [ "$UPDATE_SNIPPETS_ONLY" = true ]; then
    echo "Hook script and Template snippets updated. Reloading Script."
    exec "$0" "$@"
fi

# storage type ? (https://pve.proxmox.com/wiki/Storage)
echo -n "Get storage \"${TEMPLATE_VMSTORAGE}\" type... "
case "$(pvesh get /storage/${TEMPLATE_VMSTORAGE} --noborder --noheader | grep ^type | awk '{print $2}')" in
    dir|nfs|cifs|glusterfs|cephfs)
        TEMPLATE_VMSTORAGE_type="file"
        echo "[file]"
        ;;
    lvm|lvmthin|iscsi|iscsidirect|rbd|zfs|zfspool)
        TEMPLATE_VMSTORAGE_type="block"
        echo "[block]"
        ;;
    *)
        echo "[unknown]"
        exit 1
        ;;
esac

# Function to check if CoreOS image already exists
coreos_image_exists() {
    [[ -e fedora-coreos-${VERSION}-${PLATFORM}.${ARCHITECTURES}.qcow2 ]]
}

if ! coreos_image_exists; then
    echo "Download fedora coreos..."
    wget -q --show-progress \
        ${BASEURL}/prod/streams/${STREAMS}/builds/${VERSION}/${ARCHITECTURES}/fedora-coreos-${VERSION}-${PLATFORM}.${ARCHITECTURES}.qcow2.xz
    if [ $? -ne 0 ]; then
        echo "Failed to download Fedora CoreOS image."
        exit 1
    fi
    if ! xz -dv fedora-coreos-${VERSION}-${PLATFORM}.${ARCHITECTURES}.qcow2.xz; then
        echo "Failed to extract Fedora CoreOS image."
        exit 1
    else
        echo "Successfully extracted Fedora CoreOS image."
    fi
else
    echo "CoreOS image already exists. Skipping download."
fi

# create a new VM
echo "Create fedora coreos vm ${TEMPLATE_VMID}"
if ! qm create ${TEMPLATE_VMID} --name ${TEMPLATE_NAME}; then
    echo "Failed to create VM ${TEMPLATE_VMID}"
    exit 1
fi
qm set ${TEMPLATE_VMID} --memory 4096 \
            --cpu max \
            --cores 4 \
            --agent enabled=1 \
            --autostart \
            --onboot 1 \
            --ostype l26 \
            --tablet 0 \
            --boot c --bootdisk scsi0 \
            --machine q35 \
            --bios ovmf \
            --scsihw virtio-scsi-pci \

qm set ${TEMPLATE_VMID} --description "Fedora CoreOS - Template
 - Version             : ${VERSION}
 - Cloud-init          : true
 - Creation date       : ${template_vmcreated}"

if ! qm set ${TEMPLATE_VMID} --net0 virtio,bridge=vmbr0; then
    echo "Failed to add network interface to VM ${TEMPLATE_VMID}."
    exit 1
fi

echo -e "\nCreate Cloud-init vmdisk..."
if ! qm set ${TEMPLATE_VMID} --ide2 ${TEMPLATE_VMSTORAGE}:cloudinit; then
    echo "Failed to add Cloud-init disk to VM ${TEMPLATE_VMID}"
    exit 1
fi

# Import Fedora CoreOS disk
if [[ "${TEMPLATE_VMSTORAGE_type}" == "file" ]]; then
        vmdisk_name="${TEMPLATE_VMID}/vm-${TEMPLATE_VMID}-disk-0.qcow2"
        vmdisk_format="--format qcow2"
else
        vmdisk_name="vm-${TEMPLATE_VMID}-disk-0"
        vmdisk_format=""
fi

if ! qm importdisk ${TEMPLATE_VMID} fedora-coreos-${VERSION}-${PLATFORM}.${ARCHITECTURES}.qcow2 ${TEMPLATE_VMSTORAGE} ${vmdisk_format}; then
    echo "Failed to import Fedora CoreOS disk."
    exit 1
fi
if ! qm set ${TEMPLATE_VMID} --scsihw virtio-scsi-pci --scsi0 ${TEMPLATE_VMSTORAGE}:${vmdisk_name}${VMDISK_OPTIONS}; then
    echo "Failed to configure disk for VM ${TEMPLATE_VMID}"
    exit 1
fi

# Add EFI disk for UEFI
if ! qm set ${TEMPLATE_VMID} -efidisk0 ${TEMPLATE_VMSTORAGE}:1,efitype=4m,pre-enrolled-keys=1; then
    echo "Failed to add EFI disk for UEFI."
    exit 1
fi

# Add TPM state
if ! qm set ${TEMPLATE_VMID} -tpmstate0 ${TEMPLATE_VMSTORAGE}:1,version=v2.0; then
    echo "Failed to add TPM state to VM ${TEMPLATE_VMID}"
    exit 1
fi

# set hook-script
if ! qm set ${TEMPLATE_VMID} --hookscript ${SNIPPET_STORAGE}:snippets/hook-fcos.sh; then
    echo "Failed to set hook script for VM ${TEMPLATE_VMID}."
    exit 1
fi

# convert vm template
echo -n "Convert VM ${TEMPLATE_VMID} in proxmox vm template... "
if ! qm template ${TEMPLATE_VMID}; then
    echo "[failed]"
    exit 1
else
    echo "[done]"
fi