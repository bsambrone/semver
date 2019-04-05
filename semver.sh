#!/bin/bash

# first capture where we are so we can go back here when done
CURDIR=$(pwd)

# these vars are we need to do our thing
BUILDID=
BRANCH=
PATHTOREPO=
REPONAME=

# read in environment variables if present from vsts
if [ ${#BUILD_BUILDID} -gt 0 ]; then
BUILDID=${BUILD_BUILDID}
fi
if [ ${#BUILD_SOURCEBRANCHNAME} -gt 0 ]; then
BRANCH=$BUILD_SOURCEBRANCHNAME
fi
if [ ${#BUILD_REPOSITORY_LOCALPATH} -gt 0 ]; then
PATHTOREPO=$BUILD_REPOSITORY_LOCALPATH
fi
if [ ${#BUILD_REPOSITORY_NAME} -gt 0 ]; then
REPONAME=$BUILD_REPOSITORY_NAME
fi

# read in command line args to optionally stomp on env vars
for i in "$@"
do
case $i in
    -i=*|--build-id=*)
    BUILDID="${i#*=}"
    shift
    ;;
    -b=*|--branch=*)
    BRANCH="${i#*=}"
    shift
    ;;
    -p=*|--path=*)
    PATHTOREPO="${i#*=}"
    shift
    ;;
    -r=*|--repository=*)
    REPONAME="${i#*=}"
    shift
    ;;
    *)
          # unknown option
    ;;
esac
done

echo "BUILDID    = $BUILDID"
echo "BRANCH     = $BRANCH"
echo "PATHTOREPO = $PATHTOREPO"
echo "REPONAME   = $REPONAME"

# if missing vars, barf
if [ ${#BUILDID} -eq 0 ] || [ ${#BRANCH} -eq 0 ] || [ ${#PATHTOREPO} -eq 0 ] || [ ${#REPONAME} -eq 0 ]; then
exit 1
fi

# go to our working location
cd $PATHTOREPO

# get all the tags and sort them
TAGS=($(git tag))
IFS=$'\n' SORTEDTAGS=($(sort <<<"${TAGS[*]}"))
unset IFS

# this awful looking thing is a semver regex validator
SEMVERREGEXP="(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-(0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(\.(0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*)?(\+[0-9a-zA-Z-]+(\.[0-9a-zA-Z-]+)*)?$"

# loop through the tags to get the actual semver tags
SEMVERTAGS=()
for element in "${SORTEDTAGS[@]}"
do
   [[ $element =~ $SEMVERREGEXP ]] && SEMVERTAGS+=("$element")
done

# define a function for string position finding
strindex() { 
  x="${1%%$2*}"
  [[ "$x" = "$1" ]] && echo -1 || echo "${#x}"
}

# get the biggest tag
BIGTAG=
ISALPHA="0"
ISBETA="0"
ISRC="0"
ISPROD="0"
LASTPRODTAG=
NOALPHAREGEX="^[0-9]+([.][0-9]+)([.][0-9]+)$"
for element in "${SEMVERTAGS[@]}"
do
    echo "${element}"
   [[ $element =~ $NOALPHAREGEX ]] && LASTPRODTAG="$element"
   b=( ${element//./ } )

   # reset our latest tag build quality labels
   ISALPHA="0"
   ISBETA="0"
   ISRC="0"

   # parse out the last element in case there are build quality strings
   LASTELEM=${b[2]}

   # find out if this a non production build quality
   ISPROD="1"
   if [[ $LASTELEM == *"alpha"* ]]; then
       ISALPHA="1"
       ISPROD="0"
   fi
   if [[ $LASTELEM == *"beta"* ]]; then
       ISBETA="1"
       ISPROD="0"
   fi
   if [[ $LASTELEM == *"rc"* ]]; then
       ISRC="1"
       ISPROD="0"
   fi

   if [[ $LASTELEM == *"-"* ]]; then
        searchstring="-"
        ALMOSTPARSED=${LASTELEM%$searchstring*}
        LASTELEM="${ALMOSTPARSED%$searchstring*}"
   fi

   # reassemble the tag
   BIGTAG="${b[0]}.${b[1]}.$LASTELEM"
done

echo "Last production tag is $LASTPRODTAG"
echo "Largest base tag is $BIGTAG"

# convert the tag into an array so we can increment
a=( ${BIGTAG//./ } )

# make sure this tag is legit and we didn't goof
if [ ${#a[@]} -ne 3 ]; then
    echo "Something looks wrong with the latest base tag."
    exit 1
fi

# get the last commit to figure out the increment
INCREMENTTYPE=

# see formats here https://git-scm.com/docs/pretty-formats
#git log -1 --pretty=format:%s%n%b%n%N
IFS=$'\n'
COMMITLINES=($(git log -1 --pretty=format:%s%n%b%n%N))
unset IFS

# look at the first line for title based prefixes
TITLE=${COMMITLINES[0]}
echo "Parsing this title: $TITLE"
if [[ $TITLE == *"fix:"* ]]; then
    echo "Discovered patch semver increment"
    INCREMENTTYPE="3"
fi

if [[ $TITLE == *"feat:"* ]]; then
    echo "Discovered minor semver increment"
    INCREMENTTYPE="2"
fi

# hunt in the rest for breaking changes
for element in "${COMMITLINES[@]}"
do

    if [[ $element == *"BREAKING CHANGES"* ]]; then
        echo "Discovered major semver increment"
        INCREMENTTYPE="1"
    fi
done

if [ ${#INCREMENTTYPE} -eq 0 ]; then
    echo "Could not identify semver type from commit message"
    exit 1
fi

# debug
echo "Flags for previous commit are"
echo "ISBETA is $ISBETA"
echo "ISRC is $ISRC"
echo "ISALPHA is $ISALPHA"
echo "ISPROD is $ISPROD"
echo "Semver branch is"
echo "BRANCH is $BRANCH"

# major
if [ "$INCREMENTTYPE" == "1" ]; then
    if [[ ( ISBETA="1" && "$BRANCH" == "develop" ) || ( ISRC="1" && "$BRANCH" == *"release"* ) || ( ISPROD="1" && "$BRANCH" == "master" ) || ( ISALPHA="1" ) ]]; then
        echo "incrementing build but not semver"
    else
        ((a[0]++))
        a[1]=0
        a[2]=0
    fi
fi

# minor
if [ "$INCREMENTTYPE" == "2" ]; then
    if [[ ( ISBETA="1" && "$BRANCH" == "develop" ) || ( ISRC="1" && "$BRANCH" == *"release"* ) || ( ISPROD="1" && "$BRANCH" == "master" ) || ( ISALPHA="1" ) ]]; then
        echo "incrementing build but not semver"
    else
        ((a[1]++))
        a[2]=0
    fi
fi

# patch
if [ "$INCREMENTTYPE" == "3" ]; then
    if [[ ( ISBETA="1" && "$BRANCH" == "develop" ) || ( ISRC="1" && "$BRANCH" == *"release"* ) || ( ISPROD="1" && "$BRANCH" == "master" ) || ( ISALPHA="1" ) ]]; then
        echo "incrementing build but not semver"
    else
        ((a[2]++))
    fi
fi

# reassemble the new tag
NEWTAG="${a[0]}.${a[1]}.${a[2]}"
echo "new base tag is $NEWTAG"
SEMVER=

# based on the current branch set the build quality
SEMVER="$NEWTAG-alpha-$BUILDID"
if [ "$BRANCH" == "develop" ]; then
    SEMVER="$NEWTAG-beta-$BUILDID"
fi

if [ "$BRANCH" == *"release"* ]; then
    SEMVER="$NEWTAG-rc-$BUILDID"
fi

if [ "$BRANCH" == "master" ]; then
    FINSEMVERALTAG="$NEWTAG"
fi

export SEMVER
echo "$SEMVER"

# done, pass go and collect $200
cd $CURDIR
