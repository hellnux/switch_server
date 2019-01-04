#!/bin/bash
# Criado em 14/02/2014, by hellnux
# Version 14.0307

# MIT License
#
# Copyright (c) 2018 Danillo Costa Ferreira
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# Changelog
# 14.0307
#  - Modificado de lynx para links por conta de acesso https://
# 14.0215
#  - Implementado conceito de master e slave
# 14.0214

# TODO
# [14/02/14] Ativar notificao via email

# Crontribuicoes
# - nslookup arbitrario com IP local, em vez de 'locahost', tendo rapida resposta
#   por T.A.

#####################################################################################
#                               Funcoes
#####################################################################################

function dateNow () {
        date +%d/%m/%Y" "%k:%M:%S
}

function testPrimaryDnsServerOn(){
        ping "$ip_primary_dns_server" -c 3 -W 3 2>&1&> /dev/null
}

function testHttpOn(){
	# lynx -dump -connect_timeout=6 "$1" 2>&1&> /dev/null #sem ssl
	timeout 6 links -dump "$1" 2>&1&> /dev/null
}

function printLogSendMail(){ # separar email?
        #ip_this_server=$(hostname -i)
        #echo "$msg"
        echo "`dateNow` - $msg" | tee -a "$log_file"
        #echo -e "$msg\n\n$ip_this_server" | mail -s "[$script_name]" "$emails"
}

function reloadDNS(){
        # Reinicia o named
        /etc/rc.d/init.d/named restart 2>&1&> /dev/null
        if [ $? -eq 0 ]; then
                msg="Sucesso ao reiniciar o named."
        else
                msg="Falha ao reiniciar o named."
        fi
        printLogSendMail
        # Limpa cache de DNS
        rndc flushname "$domain" 2>&1&> /dev/null # estilo flusdns
        if [ $? -eq 0 ]; then
                msg="Sucesso ao limpar cache DNS de $domain"
        else
                msg="Falha ao limpar cache DNS de $domain"
        fi
        /scripts/dnscluster synczone "$domain"
        printLogSendMail
}

function changeIpZone(){
        sed -i "s/$1/$2/g" "$zone_file"
        if [ $? -eq 0 ]; then
                msg="IP atualizado de $1 para $2."
        else
                msg="Houve falha ao atualizar o IP."
        fi
        printLogSendMail
}

function changeSerialNumber(){ # tem qe verificar se a data bate com a atual
        change_sn="yes"
        ## Pega Serial Number e verifca se e valido ##
        sn_actual=$(sed -n 5p "$zone_file" | awk '{print $1}')
        if [ "$sn_actual" == "" ]; then
                msg="Error: Serial Number nao encontrado. Apenas o IP sera atualizado."
                printLogSendMail
                change_sn="no"
        fi
        #echo "1- $sn_actual" #debug
        if ! let $sn_actual 2> /dev/null; then # nao e numero inteiro
                sn_actual=$(host -t SOA "$domain" | awk '{print $7}') # pega SN por outro metodo
                #echo "2- $sn_actual" #debug
                if ! let $sn_actual 2> /dev/null; then
                        msg="Error: Serial Number nao encontrado. Apenas o IP sera atualizado."
                        printLogSendMail
                fi
        fi
        if [ ${#sn_actual} -ne 10 ]; then # diferente de 10 caracteres
                msg="Warning: Serial Number esta com formato incorreto. Apenas o IP sera atualizado."
                printLogSendMail
        elif [ ${sn_actual:8} -eq 99 ]; then # maximo 99 alteracoes
                msg="Warning: Ja houve 99 alteracoes. Apenas o IP sera atualizado."
                printLogSendMail
        fi
        ## Seta Serial Number novo e modifica ##
        if [ "$change_sn" == "yes" ]; then
                sn_actual_date=${sn_actual::8} # 8 primeiros caracteres do SN
                sn_date_now=$(date +%Y%m%d)
                #echo "sn_actual_date: $sn_actual_date" #debug
                #echo "sn_date_now: $sn_date_now" #debug
                if [ "$sn_actual_date" == "$sn_date_now" ] ; then
                        sn_new=$(( $sn_actual + 1 ))
                else
                        version="01"
                        sn_new="$sn_date_now$version"
                fi
                #echo "sn_actual: $sn_actual - sn_new: $sn_new" #debug
                sed -i "s/$sn_actual/$sn_new/g" "$zone_file"
                if [ $? -eq 0 ]; then
                        msg="Serial Number atualizado de $sn_actual para $sn_new."
                        printLogSendMail
                else
                        msg="Houve falha ao atualizar o Serial Number."
                        printLogSendMail
                fi
        fi
        ## Metodo para SN quando nao se sabe onde esta
        ##n_line_soa=$(nl -ba "$zone_file" | grep -Fw "SOA" | awk '{print $1}') # numero linha SOA
        ##n_line_sn=$(( $n_line_soa + 1  )) # numero linha SerialNumber
}

function _main_(){
        #ip_zone=$(gethostip "$domain" | awk '{print $2}')
        ip_this_server=$(hostname -i)
        ip_zone=$(nslookup "$domain" "$ip_this_server" | grep "Address:" | grep -v "#53" | awk '{print $NF}')
        echo -e "\n[init loop]\nip_zone:$ip_zone:" #debug
        if [ "$ip_zone" == "$ip_1" ]; then
                testHttpOn $link_primario
                if [ $? -ne 0 ]; then # primario offline
                        echo "[`dateNow`] sleep $delay_recheck" #debug
                        sleep "$delay_recheck"
                        testHttpOn $link_primario
                        if [ $? -ne 0 ]; then # primario offline
                                testHttpOn $link_secundario
                                if [ $? -eq 0 ]; then # secundario online
                                        changeIpZone "$ip_1" "$ip_2" #altera para o secundario
                                        changeSerialNumber
                                        reloadDNS
                                        #echo "[`dateNow`] sleep $delay_changed_ip" #debug
                                        #sleep "$delay_changed_ip"
                                else # secundario offline
                                        msg="Warning: Os dois links estao inacessiveis."
                                        printLogSendMail
                                fi
                        fi
                #else # primario online
                #       # altera ip para o primeiro, caso esteja no secundario
                #       if [ "`grep -F "$ip_2" "$zone_file"`" != "" ]; then
                #               changeIpZone "$ip_2" "$ip_1" #altera para o primario
                #               changeSerialNumber
                #               reloadDNS
                #               echo "[`dateNow`] sleep $delay_changed_ip" #debug
                #               sleep "$delay_changed_ip"
                #       fi
                fi
        elif [ "$ip_zone" == "$ip_2" ]; then
                testHttpOn $link_primario
                if [ $? -eq 0 ]; then # primario online
                        changeIpZone "$ip_2" "$ip_1" #altera para o primario
                        changeSerialNumber
                        reloadDNS
                        #echo "[`dateNow`] sleep $delay_changed_ip" #debug
                        #sleep "$delay_changed_ip"
                fi
        fi
        echo "[`dateNow`] sleep $delay" #debug
        sleep "$delay"
}

#####################################################################################
#                                       Main
#####################################################################################

mode="master" # master or slave
script_name=$(basename $0 .sh)
emails="a@mail.com"
ip_1="186.202.145.44"
ip_2="189.1.163.244"
ip_primary_dns_server="69.4.225.147"
delay=10 #segundos
delay_recheck=20 #segundos
#delay_changed_ip=50 #segundos
domain="medicinadireta.com.br"
zone_file="/var/named/$domain.db"
log_file="/root/scripts/logs/$script_name.log"
link_primario="http://$ip_1/~medicina/monitor-sh.html"
link_secundario="http://$ip_2/~medicina/monitor-sh.html"

# Garante que o diretorio de log exista
mkdir -p /root/scripts/logs 2> /dev/null

# Checa se a zona existe
if [ ! -e "$zone_file" ]; then
        echo "Error: $zone_file nao encontrado."
        exit 1
fi

echo "[$mode]" #debug
echo "Link primario: $link_primario" # debug
if [ "$mode" == "slave" ]; then
        while [ 1 ]; do
                testPrimaryDnsServerOn
                if [ $? -ne 0 ]; then
                        sleep 2
                        testPrimaryDnsServerOn
                        if [ $? -ne 0 ]; then
                                _main_
                        fi
                fi
        done
else # master
        while [ 1 ]; do
                _main_
        done
fi
