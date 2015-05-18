#!/bin/bash
#
# courier/vpopmail Maildir to Zimbra Import
#
# This script can be stored anywhere, but you should run it while in the root
# of the domain's users.  It looks for the file vpasswd which contains a
# line-separated list of users and uses that to import.  You can also run the
# script with a user name to process a single user.  Additionally, you can
# specify a folder name (courier format) to process a single folder for that
# user.

# We assume the folder structure is like this:
# Inbox: <working directory>/<user>/Maildir/<cur|new>
# Subfolder: <working directory>/<user>/Maildir/.Subfolder/<cur|new>
# If this is not what your structure looks like, you need to change the
# "folderpath" variable construction down further in this script.

# This is the command to run to run mailbox commands.
ZMCMD='/opt/zimbra/bin/zmmailbox -z'
# This will be used for temporary/log files during the import process
TEMP='/tmp'
# Absolute path to vmail
VMAIL='/home/vmail'
# Mailbox destination path to import all mail to 
MBOXBASE='Archive'

echo Process ID: $$
cd $VMAIL

DOMAINS=`find ./ -maxdepth 1 -mindepth 1 -type d | cut -f 2 -d/ | sort`
for domain in $DOMAINS; do
  echo "Beginning Domain: $domain ..."

  USERS=`find ./$domain/ -maxdepth 1 -mindepth 1 -type d | cut -f3 -d/ | sort`
  for user in $USERS; do
    echo "Beginning User: $user ..."

    # Drop ${MBOXBASE} folder
    #${ZMCMD} -m ${user}@${domain} getFolder "/$MBOXBASE" >/dev/null 2>&1 &&
    #    ( 
    echo -n "  + Delete folder $MBOXBASE ... "
    ${ZMCMD} -m ${user}@${domain} deleteFolder "/$MBOXBASE" &>/dev/null && echo "done"

    # )

    FOLDERS=`find ./$domain/$user -type d -name cur | sort`

    echo "$FOLDERS" | while read line; do
      folderdir=`echo ${line} | cut -f4 -d"/"`
      if [[ ${folderdir} == "cur" ]] ; then
        folderdir=""
        folderpath=${VMAIL}/${domain}/${user}/
      else
        folderpath=${VMAIL}/${domain}/${user}/${folderdir}/
      fi 
      folder=`echo ${folderdir} | sed 's/^\.//; s%\.%/%g; s%\&-%\&%g'`
      
      # If the folder name is blank, this is the top level folder,
      # Zimbra calls it "Inbox" (so do most clients/servers).
      if [[ $folder == "" ]] ; then
        folder="Inbox";
      fi
      # In Courier IMAP, all folders must be children of the root
      # folder, which means Trash, Junk, Sent, Drafts are typically
      # under Inbox. This is not the case with Zimbra, so we will
      # slide these mailboxes to the top level so they behave properly,
      # For all "non-special" mailboxes, we will keep them as children
      # so they remain where the user had them before.
      if [[ $folder != "Trash" && $folder != "Junk" && $folder != "Sent"
         && $folder != "Drafts" && $folder != "Inbox" ]] ; then
        folder="Inbox/${folder}";
      fi
      echo "* Working on Folder $folder..."

      # Add hierarcy: /Archive/domain.com/username
      folder="${MBOXBASE}/${domain}/${folder}"
      echo -n "  + Creating $folder ..."

      # Courier allows heirarchy where non-folders (literally nothing) are
      # able to have children.  Zimbra does not.  It's also possible that
      # we will process the folders out of heirarchical order for some reason
      # Here we separate the path and make sure all the parent folders exist
      # before trying to create the folder we're working on.
      # Creating folder whithout existance checking. Dirty but works faster.
      # Suppressing output to avoid mess. The error will be thrown during
      # mail import if folder does not exist.
      parts=(`echo $folder | sed 's% %\x1a%g; s%/% %g'`);
      hier="";
      cmdlist=()
      for i in "${parts[@]}"; do
        hier=`echo ${hier}/$i | sed 's%^/%%; s%\x1a% %g'`;
        #${ZMCMD} -m ${user}@${domain} getFolder "/${hier}" &>/dev/null ||
        #( echo -n "  + Creating folder $hier... " &&
        #${ZMCMD} -m ${user}@${domain} createFolder "/${hier}" )
        cmdlist+=("createFolder '/${hier}'")
      done
      printf '%s\n' "${cmdlist[@]}" | ${ZMCMD} -m ${user}@${domain} &>/dev/null && echo "done"

      # Figure out how many messages we have
      count=`find "${folderpath}new/" "${folderpath}cur/" -type f | wc -l`;
      imported=0;
      echo "  * $count messages to process..."

      # Define the temporary file names we will need
      importfn="${TEMP}/import-$domain-$user-$folderdir-$$"
      implogfn="${TEMP}/import-$domain-$user-$folderdir-$$-log"
      impflogfn="${TEMP}/import-$domain-$user-$folderdir-$$-flaglog"
      impflagfn="${TEMP}/import-$domain-$user-$folderdir-$$-flags"
      touch "$importfn"

      # Determine the courier extended flag identifiers ("keywords")
      flagid=0
      if [[ -f "${folderpath}courierimapkeywords/:list" ]] ; then
        extflags="YES"
        cat "${folderpath}courierimapkeywords/:list" 2>/dev/null | while read line; do
          # A blank line indicates the end of the definitions.
          if [[ "${line}" == "" ]]; then break; fi

          # To avoid escape character madness, I'm swapping $ with % here.
          flag=`echo ${line} | sed 's/\\\$/%/'`
          echo courierflag[${flagid}]="'$flag'";
          flagid=$(( flagid + 1 ));

          # Create the tag if it doesn't start with '%'
          if [[ `echo ${flag} | grep '%'` == "" ]] ; then
            echo -n "  + Attemping to create tag ${flag}... " >&2
            ${ZMCMD} -m ${user}@${domain} createTag "${flag}" >&2
          fi

        done > "$impflagfn"
        source "$impflagfn"
      fi

      echo -n "  * Queuing messages for import...        " 

      # Find all "cur" or "new" messages in this folder and import them.
      find "${folderpath}new/" "${folderpath}cur/" -type f | while read msg; do
        flags="";
        tags="";
        msgid=`echo $msg | cut -d: -f1 | sed s%.*/%%`

        # Determine the old maildir style flags
        oldflags=`echo $msg | cut -d: -f2`
        # Replied
        if [[ `echo ${oldflags} | grep 'R'` != "" ]] ; then flags="${flags}r"; fi
        # Seen
        if [[ `echo ${oldflags} | grep 'S'` == "" ]] ; then flags="${flags}u"; fi
        # Trashed
        if [[ `echo ${oldflags} | grep 'T'` != "" ]] ; then flags="${flags}x"; fi
        # Draft
        if [[ `echo ${oldflags} | grep 'D'` != "" ]] ; then flags="${flags}d"; fi
        # Flagged
        if [[ `echo ${oldflags} | grep 'F'` != "" ]] ; then flags="${flags}f"; fi

        # Determine the courier-imap extended flags for this message
        if [[ ${extflags} == "YES" ]] ; then
          oldflags2=`grep $msgid "${folderpath}courierimapkeywords/:list" 2>/dev/null | cut -d: -f2`
          for flag in ${oldflags2}; do
            # Forwarded
            if [[ ${courierflag[$flag]} == '%Forwarded' ]] ; then flags="${flags}w"; fi
            # Sent by me
            if [[ ${courierflag[$flag]} == '%MDNSent' ]] ;   then flags="${flags}s"; fi
            # Convert non-system flags to Zimbra tags
            if [[ `echo ${courierflag[$flag]} | grep '%'` == "" ]] ; then
              tags="${tags},${courierflag[$flag]}"
            fi
          done
          # Clean up the tag list for the command line
          if [[ ${tags} != "" ]]; then
            tags=`echo ${tags} | sed "s/^,\?/--tags \'/; s/\$/\'/"`;
          fi
        fi

        # Log the result of flag processing for debugging
        if [[ $flags != "" || $tags != "" ]] ; then
          echo `date +%c` "$msg had flags $oldflags and $oldflags2, now $flags and $tags in folder $folder" >> "$impflogfn"
        fi

        # Add the command to the queue file to import this message
        echo "addMessage --flags \"${flags}\" ${tags} --noValidation \"/$folder\" \"${msg}\"" >> "$importfn"

        imported=$(( $imported + 1 ));
        printf "\b\b\b\b\b\b\b\b%7d " $imported;
      done

      echo "...done";

      # Since we redirect the queue file to the mailbox tool, we end with "quit"
      echo "quit" >> "$importfn"

      # We're counting "prompts" from the zmmailbox utility here.  The first
      # one comes up before a message is imported, so we start at -3 to offset
      # its existence.
      imported=0;

      # We do this redirect because running the command for each message is very
      # slow.  We can't just pass the directory to the command, despite Zimbra's
      # support because we can't tag or flag the messages that way.
      echo -n "  * Running import process...             "
      ${ZMCMD} -m $user@$domain < "${importfn}" 2> "${implogfn}" | while read line; do
        # count only addMessage commands, as we have other garbage in output
        if echo $line | grep addMessage &>/dev/null; then
          imported=$(( $imported + 1 )) # && 
          printf "\b\b\b\b\b\b\b\b%7d " $imported
        fi
      done

      if [[ -s "${implogfn}" ]]; then 
        echo "...some messages did not import correctly: check $importfn";
      else
        echo "...done";
      fi
    done
  done
done

echo "Import Process Complete!"
