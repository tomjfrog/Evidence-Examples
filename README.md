# Attach Evidence in Artifactory

Artifactory enables you to attach evidence (signed metadata) to a designated subject, such as an artifact, build, package, or Release Bundle v2. These evidence files provide a record of an external process performed on the subject, such as test results, vulnerability scans, or official approval.

This document describes how to use the JFrog CLI to create different types of evidence related to a Docker image deployed to Artifactory, including:

* Package evidence
* Generic evidence
* Build evidence
* Release Bundle evidence   

The following workflow is described:

1. [Bootstrapping](#bootstrapping)  
   1. [Install JFrog CLI](#install-jfrog-cli)  
   2. [Log In to the Artifactory Docker Registry](#log-in-to-the-artifactory-docker-registry)  
2. [Build the Docker Image](#build-the-docker-image)  
3. [Attach Package Evidence](#attach-package-evidence)  
4. [Upload README File and Associated Evidence](#upload-readme-file-and-associated-evidence)  
5. [Publish Build Info and Attach Build Evidence](#publish-build-info-and-attach-build-evidence)  
6. [Create a Release Bundle v2 from the Build](#create-a-release-bundle-v2-from-the-build)  
7. [Attach Release Bundle Evidence](#attach-release-bundle-evidence)
8. [Create an External Policy to Potentially Block Release Bundle Promotion](#create-an-external-policy-to-potentially-block-release-bundle-promotion)

Refer to [build.yml](https://github.com/jfrog/Evidence-Examples/tree/main/.github/workflows/build.yml) for the complete script.

***

## Note

For more information about evidence on the JFrog platform, see Evidence Management.
***

## Prerequisites

* Make sure JFrog CLI 2.65.0 or above is installed and in your system PATH. For installation instructions, see [Install JFrog CLI](#bootstrapping).  
* Make sure Artifactory can be used as a Docker registry. Please refer to [Getting Started with Artifactory as a Docker Registry](https://www.jfrog.com/confluence/display/JFROG/Getting+Started+with+Artifactory+as+a+Docker+Registry) in the JFrog Artifactory User Guide. You should end up with a Docker registry URL, which is mapped to a local Docker repository (or a virtual Docker repository with a local deployment target) in Artifactory. You'll need to know the name of the Docker repository to later collect the published image build-info.  
* Make sure the following repository variables are configured in GitHub settings:  
  * ARTIFACTORY_URL (location of your Artifactory installation)  
  * BUILD_NAME (planned name for the build of the Docker image)  
  * BUNDLE_NAME (planned name for the Release Bundle created from the build)  
* Make sure the following repository secrets are configured in GitHub settings:  
  * ARTIFACTORY_ACCESS_TOKEN (access token used for authentication)  
  * JF_USER (your username in Artifactory)  
  * PRIVATE_KEY (the key used to sign evidence)



## Bootstrapping

### Install JFrog CLI

This section of [build.yml](https://github.com/jfrog/Evidence-Examples/tree/main/.github/workflows/build.yml) installs the latest version of the JFrog CLI and performs checkout. This example uses Github OIDC to exchange a Github Identity Token for a short-lived access token to JFrog Artifactory.

```yaml
jobs:  
  Docker-build-with-evidence:  
    runs-on: ubuntu-latest  
    steps:
      - name: Install JFrog CLI
        uses: jfrog/setup-jfrog-cli@v4
        id: cli
        env:
          JF_URL: ${{ vars.JF_URL }}
#          JF_PROJECT: ${{ vars.JF_URL }}
        with:
          oidc-provider-name: github-oidc-integration
          oidc-audience: jfrog-github
          disable-auto-build-publish: true

      - uses: actions/checkout@v4
```

### Log In to the Artifactory Docker Registry

This section of [build.yml](https://github.com/jfrog/Evidence-Examples/tree/main/.github/workflows/build.yml) logs into the Docker registry, as described in the [prerequisites](#prerequisites), and sets up QEMU and Docker Buildx in preparation for building the Docker image.

```yaml
  - name: Log in to Artifactory Docker Registry
    uses: docker/login-action@v3
    with:
      registry: ${{ vars.ARTIFACTORY_URL }}
      username: ${{ steps.cli.outputs.oidc-user }}
      password: ${{ steps.cli.outputs.oidc-token }}

  - name: Set up QEMU
    id: setup-qemu
    uses: docker/setup-qemu-action@v3

  - name: Set up Docker Buildx
    id: setup-buildx
    uses: docker/setup-buildx-action@v3
    with:
      platforms: linux/amd64,linux/arm64
      install: true
```
### Provision Signing Key for Evidence Signature
This will provision a signing key for the evidence signature. The signing key is used to sign the evidence files that are created during the build process.  The public key is stored in the JFrog Platform and referenced by Alias name. This allows for signing verification in the workflow.

```yaml
  - name: Setup Signing Key
    id: setup-signing-key
    run: |
      echo "${{ secrets.PRIVATE_KEY_EXPORT }}" > "${{ secrets.PRIVATE_KEY_NAME }}"
      chmod 600 ${{ secrets.PRIVATE_KEY_NAME }}
      openssl rsa -in ${{ secrets.PRIVATE_KEY_NAME }} -check
```

## Build the Docker Image

This section of [build.yml](https://github.com/jfrog/Evidence-Examples/tree/main/.github/workflows/build.yml) builds the Docker image and deploys it to Artifactory.

```yaml
      - name: Build Docker image
        run: |
          URL=$(echo ${{ vars.ARTIFACTORY_URL }} | sed 's|^https://||')
          REPO_URL=${URL}'/${{ env.DOCKER_VIRTUAL}}'
          docker build \
          --build-arg REPO_URL=${REPO_URL} \
          -f Dockerfile . \
          --tag ${REPO_URL}/${{ env.IMAGE_NAME }}:${{ github.run_number }} \
          --output=type=image \
          --platform linux/amd64 \
          --metadata-file=${{ env.DOCKER_METADATA }} \
          --push
```
## Generate a Build Info for the Docker Build
This will generate a Build Info for the Docker image, which we will continue to augment with additional Build information during the workflow.  The Build Info will be signed with a simple attestation and uploaded to Artficatory in a subsequent step
```yaml
  - name: Create Docker Build Info
    run: |
      jf rt build-docker-create ${{ vars.DOCKER_VIRTUAL}} \
      --image-file ${{ env.DOCKER_METADATA }} \
      --build-name ${{ vars.BUILD_NAME }} \
      --build-number ${{ github.run_number }}
```

## Attach Package Evidence

This section of [build.yml](https://github.com/jfrog/Evidence-Examples/tree/main/.github/workflows/build.yml) creates evidence for the package containing the Docker image. The evidence is signed with your private key, as defined in the [Prerequisites](#prerequisites).

```yaml
  - name: Create and Attach Evidence on Docker Image
    run: |
      echo '{ "actor": "${{ github.actor }}", "date": "'$(date -u +"%Y-%m-%dT%H:%M:%SZ")'" }' > sign.json
      jf evd create \
      --package-name ${{ env.IMAGE_NAME }} \
      --package-version ${{ github.run_number }} \
      --package-repo-name ${{ env.DOCKER_LOCAL }} \
      --key "${{ env.PRIVATE_KEY_NAME }}" \
      --key-alias ${{ env.KEY_ALIAS }} \
      --predicate ./sign.json \
      --predicate-type https://jfrog.com/evidence/signature/v1 
      echo '🔎 Evidence attached: `signature` 🔏 ' 

```

## Upload README File and Associated Evidence

This section of [build.yml](https://github.com/jfrog/Evidence-Examples/tree/main/.github/workflows/build.yml) uploads the README file and creates signed evidence about this generic artifact. The purpose of this section is to demonstrate the ability to create evidence for any type of file uploaded to Artifactory, in addition to packages, builds, and Release Bundles.

```yaml
  - name: Upload README file
    run: |
      jf rt upload ./README.md ${{ env.GENERIC_LOCAL }}/readme/${{ github.run_number }}/ \
      --build-name ${{ vars.BUILD_NAME }} \
      --build-number ${{ github.run_number }}

  - name: Attach Evidence on README file
    run: |
      jf evd create \
      --subject-repo-path ${{ env.GENERIC_LOCAL }}/readme/${{ github.run_number }}/README.md \
      --key "${{ env.PRIVATE_KEY_NAME }}" \
      --key-alias ${{ env.KEY_ALIAS }} \
      --predicate ./sign.json \
      --predicate-type https://jfrog.com/evidence/signature/v1 \
      --project ${{ env.JF_PROJECT }} \
```

## Decorate Build Info with additional Metadata
Build Info should collect as much information as possible about the Build environment & Git Info

## Publish Build Info and Attach Build Evidence

This section of [build.yml](https://github.com/jfrog/Evidence-Examples/tree/main/.github/workflows/build.yml) creates a build from the package containing the Docker image and then creates signed evidence attesting to its creation.

```yaml
  - name: Publish build info  
    run: jfrog rt build-publish ${{ vars.BUILD_NAME }} ${{ github.run_number }}

  - name: Sign build evidence  
    run: |  
      echo '{ "actor": "${{ github.actor }}", "date": "'$(date -u +"%Y-%m-%dT%H:%M:%SZ")'" }' > sign.json  
      jf evd create --build-name ${{ vars.BUILD_NAME }} --build-number ${{ github.run_number }} \
        --predicate ./sign.json --predicate-type https://jfrog.com/evidence/build-signature/v1 \
        --key "${{ secrets.PRIVATE_KEY }}"  
      echo ' Evidence attached: `build-signature` ' >> $GITHUB_STEP_SUMMARY
```

## Create a Release Bundle v2 from the Build

This section of [build.yml](https://github.com/jfrog/Evidence-Examples/tree/main/.github/workflows/build.yml) creates an immutable Release Bundle v2 from the build containing the Docker image. Having a Release Bundle prevents any changes to the Docker image as it progresses through the various stages of your SDLC towards eventual distribution to your end users.

```yaml
- name: Create release bundle  
  run: |  
    echo '{ "files": [ {"build": "'"${{ vars.BUILD_NAME }}/${{ github.run_number }}"'" } ] }' > bundle-spec.json  
    jf release-bundle-create ${{ vars.BUNDLE_NAME }} ${{ github.run_number }} --signing-key PGP-RSA-2048 --spec bundle-spec.json --sync=true  
    NAME_LINK=${{ vars.ARTIFACTORY_URL }}'/ui/artifactory/lifecycle/?bundleName='${{ vars.BUNDLE_NAME }}'&bundleToFlash='${{ vars.BUNDLE_NAME }}'&repositoryKey=example-project-release-bundles-v2&activeKanbanTab=promotion'  
    VER_LINK=${{ vars.ARTIFACTORY_URL }}'/ui/artifactory/lifecycle/?bundleName='${{ vars.BUNDLE_NAME }}'&bundleToFlash='${{ vars.BUNDLE_NAME }}'&releaseBundleVersion='${{ github.run_number }}'&repositoryKey=example-project-release-bundles-v2&activeVersionTab=Version%20Timeline&activeKanbanTab=promotion'  
    echo ' Release bundle ['${{ vars.BUNDLE_NAME }}']('${NAME_LINK}'):['${{ github.run_number }}']('${VER_LINK}') created' >> $GITHUB_STEP_SUMMARY
```

***

**Note**

For more information about using the JFrog CLI to create a Release Bundle, see [https://docs.jfrog-applications.jfrog.io/jfrog-applications/jfrog-cli/cli-for-jfrog-artifactory/release-lifecycle-management](https://docs.jfrog-applications.jfrog.io/jfrog-applications/jfrog-cli/cli-for-jfrog-artifactory/release-lifecycle-management).
***

## Attach Release Bundle Evidence

This section of [build.yml](https://github.com/jfrog/Evidence-Examples/tree/main/.github/workflows/build.yml) creates signed evidence about the Release Bundle. 

```yaml
 - name: Evidence on release-bundle v2  
   run: |  
     echo '{ "actor": "${{ github.actor }}", "date": "'$(date -u +"%Y-%m-%dT%H:%M:%SZ")'" }' > rbv2_evidence.json  
     JF_LINK=${{ vars.ARTIFACTORY_URL }}'/ui/artifactory/lifecycle/?bundleName='${{ vars.BUNDLE_NAME }}'&bundleToFlash='${{ vars.BUNDLE_NAME }}'&releaseBundleVersion='${{ github.run_number }}'&repositoryKey=release-bundles-v2&activeVersionTab=Version%20Timeline&activeKanbanTab=promotion'  
     echo 'Test on Release bundle ['${{ vars.BUNDLE_NAME }}':'${{ github.run_number }}']('${JF_LINK}') success' >> $GITHUB_STEP_SUMMARY  
     jf evd create --release-bundle ${{ vars.BUNDLE_NAME }} --release-bundle-version ${{ github.run_number }} \  
       --predicate ./rbv2_evidence.json --predicate-type https://jfrog.com/evidence/rbv2-signature/v1 \  
       --key "${{ secrets.PRIVATE_KEY }}"  
     echo ' Evidence attached: integration-test ' >> $GITHUB_STEP_SUMMARY  
```

## Create an External Policy to Potentially Block Release Bundle Promotion

When the Evidence service is used in conjunction with JFrog Xray, each Release Bundle promotion generates evidence in the form of a CycloneDX SBOM. You can create a policy in an external tool (for example, a rego policy) that reviews the contents of the CycloneDX evidence file and decides whether to block the promotion (because the Release Bundle fails to meet all your organization's requirements for promotion to the next stage of your SDLC).

To see a sample rego policy, go [here](https://github.com/jfrog/Evidence-Examples/blob/main/policy/policy.rego).
For more information about integrating Release Lifecycle Management and Evidence with Xray, see [Scan Release Bundles (v2) with Xray](https://jfrog.com/help/r/jfrog-artifactory-documentation/scan-release-bundles-v2-with-xray).

## Sequence Diagram
```mermaid
sequenceDiagram
autonumber
actor GitHub
participant Docker
participant JFrog
participant OPA
participant QA
participant PROD

    GitHub->>Docker: Build Docker Image
    Docker->>JFrog: Push Image
    GitHub->>JFrog: Create Build Info & Metadata
    GitHub->>JFrog: Attach Evidence on Image
    GitHub->>JFrog: Upload README.md
    GitHub->>JFrog: Attach Evidence on README
    GitHub->>JFrog: Decorate & Publish Build Info
    GitHub->>JFrog: Sign Build Evidence
    GitHub->>JFrog: Create Release Bundle

    GitHub->>QA: Promote Release Bundle to QA
    QA->>JFrog: Attach Integration Test Evidence

    GitHub->>OPA: Run Policy Check on Evidence Graph
    alt Policy Approved
        GitHub->>JFrog: Attach Approval Evidence
        GitHub->>PROD: Promote to Production
    else Policy Rejected
        GitHub->>GitHub: Fail with Policy Violation
    end
```
