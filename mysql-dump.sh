#!/bin/bash

##########################################################################
###
###      Author: Rahul Kumar
###      Contributors: David Klein
###      Email: rahul@tecadmin.net
###      Website: https://tecadmin.net
###      Version 3.2
###
##########################################################################

CONFIGFILE=/etc/mydumpadmin/settings.conf
source $CONFIGFILE
if [ $? == 1 ]; then
        kill -9 $$
fi

TIME_FORMAT='%d%m%Y-%H%M%S'
cTime=$(date +"${TIME_FORMAT}")
LOGFILENAME=$LOG_PATH/mydumpadmin-${cTime}.txt
touch $LOGFILENAME

CREDENTIALS="--defaults-extra-file=$CREDENTIAL_FILE"

[ ! -d $LOG_PATH ] && ${MKDIR} -p ${LOG_PATH}

### GET GIT TAG ###
get_git_tag(){
        cd $GIT_REPO_PATH
        TAGVERSION=`$GITBIN status | $SED -rn 's/.*HEAD detached at (v[0-9]\.[0-9]\.[0-9]).*/\1/p'`
        if [[ $TAGVERSION == "" ]]; then
                TAGVERSION="NOTAG"
        fi
}

### Make a backup ###
check_config(){
        [ ! -f $CONFIGFILE ] && close_on_error "Config file not found, make sure config file is correct"
        return 0
}
db_backup(){
        if [ "$DB_NAMES" == "ALL" ]; then
                DATABASES=`$MYSQL $CREDENTIALS -h $MYSQL_HOST -P $MYSQL_PORT -Bse 'show databases' | grep -Ev "^(Database|mysql|performance_schema|information_schema)"$`
        else
                DATABASES=$DB_NAMES
        fi

        db=""
        [ ! -d $BACKUPDIR ] && ${MKDIR} -p $BACKUPDIR
                [ $VERBOSE -eq 1 ] && echo "*** Dumping MySQL Database ***"
                mkdir -p ${LOCAL_BACKUP_DIR}/${cTime}
        for db in $DATABASES
        do
                if [ $GIT_ENABLE -eq 1 ]; then
                        FILE_NAME="${SUBDOMAIN}.${db}.${cTime}.${TAGVERSION}.gz"    
                else
                        FILE_NAME="${SUBDOMAIN}.${db}.${cTime}.gz"
                fi
                FILE_PATH="${LOCAL_BACKUP_DIR}/${cTime}/"
                FILENAMEPATH="$FILE_PATH$FILE_NAME"
                [ $VERBOSE -eq 1 ] && echo -en "Database> $db... \n"
                ${MYSQLDUMP} ${CREDENTIALS} -h ${MYSQL_HOST} -P $MYSQL_PORT $db | ${GZIP} -9 > $FILENAMEPATH
                [ $FTP_ENABLE -eq 1 ] && ftp_backup
                [ $SFTP_ENABLE -eq 1 ] && sftp_backup
                [ $S3_ENABLE -eq 1 ] && s3_backup
        done
        [ $VERBOSE -eq 1 ] && echo "*** Backup completed ***"
        [ $VERBOSE -eq 1 ] && echo "*** Check backup files in ${FILE_PATH} ***"
}

### close_on_error on demand with message ###
close_on_error(){
        echo "$@"
        return 99
}

### Make sure bins exists.. else close_on_error
check_cmds(){
        [ ! -x $GZIP ] && close_on_error "FILENAME $GZIP does not exists. Make sure correct path is set in $CONFIGFILE."
        [ ! -x $MYSQL ] && close_on_error "FILENAME $MYSQL does not exists. Make sure correct path is set in $CONFIGFILE."
        [ ! -x $MYSQLDUMP ] && close_on_error "FILENAME $MYSQLDUMP does not exists. Make sure correct path is set in $CONFIGFILE."
        [ ! -x $RM ] && close_on_error "FILENAME $RM does not exists. Make sure correct path is set in $CONFIGFILE."
        [ ! -x $MKDIR ] && close_on_error "FILENAME $MKDIR does not exists. Make sure correct path is set in $CONFIGFILE."
        [ ! -x $MYSQLADMIN ] && close_on_error "FILENAME $MYSQLADMIN does not exists. Make sure correct path is set in $CONFIGFILE."
        [ ! -x $GREP ] && close_on_error "FILENAME $GREP does not exists. Make sure correct path is set in $CONFIGFILE."
        [ ! -x $SED ] && close_on_error "FILENAME $SED does not exists. Make sure correct path is set in $CONFIGFILE."
        if [ $S3_ENABLE -eq 1 ]; then
                [ ! -x $S3CMD ] && close_on_error "FILENAME $S3CMD does not exists. Make sure correct path is set in $CONFIGFILE."
        fi
        if [ $SFTP_ENABLE -eq 1 ]; then
                [ ! -x $SCP ] && close_on_error "FILENAME $SCP does not exists. Make sure correct path is set in $CONFIGFILE."
        fi
}

### Make sure we can connect to server ...
check_mysql_connection(){
        ${MYSQLADMIN} ${CREDENTIALS} -h ${MYSQL_HOST} -P ${MYSQL_PORT} ping | ${GREP} 'alive'>/dev/null
        [ $? -eq 0 ] || close_on_error "Error: Cannot connect to MySQL Server. Make sure username and password setup correctly in $CONFIGFILE"
}




ftp_backup(){
[ $VERBOSE -eq 1 ] && echo "Uploading backup file to FTP"
ftp -n $FTP_SERVER << EndFTP
user "$FTP_USERNAME" "$FTP_PASSWORD"
binary
hash
cd $FTP_UPLOAD_DIR
lcd $FILE_PATH
put "$FILE_NAME"
bye
EndFTP
}

sftp_backup(){

        [ $VERBOSE -eq 1 ] && echo "Uploading backup file to SFTP"
        cd ${FILE_PATH}
        ${SCP} -P ${SFTP_PORT}  "$FILE_NAME" ${SFTP_USERNAME}@${SFTP_HOST}:${SFTP_UPLOAD_DIR}/

}

s3_backup(){
        [ $VERBOSE -eq 1 ] && echo "Uploading backup file to S3 Bucket"
        cd ${FILE_PATH}
        $S3CMD s3 cp --only-show-errors "$FILE_NAME" s3://${S3_BUCKET_NAME}/${S3_UPLOAD_LOCATION}/ 2> ${LOGFILENAME}
}


send_report(){
        if [ $SENDEMAIL -eq 1 ]
        then
                cat ${LOGFILENAME} | mail -vs "Database dump report for `date +%D`" ${EMAILTO}
        fi
        if [ $SENDSLACK -eq 1 ]
        then
                echo "sending slack report"
                ${CURL} -X POST --data-urlencode "payload={\"text\": \"$(cat ${LOGFILENAME})\"}" ${SLACKWH}
        fi
}

echo "step 1"
check_config >> ${LOGFILENAME}
echo "step 2"
check_cmds >> ${LOGFILENAME}
echo "step 3"
get_git_tag >> ${LOGFILENAME}
echo "step 4"
check_mysql_connection >> ${LOGFILENAME}
echo "step 5"
db_backup >> ${LOGFILENAME}
echo "step 6"

if [ $(wc -l < "${LOGFILENAME}") == "0" ]; then
        echo "BACKUP SUCCESS at $SUBDOMAIN" > ${LOGFILENAME}
else
        echo "ERROR at $SUBDOMAIN" >> ${LOGFILENAME}    
fi

send_report
exit 0
