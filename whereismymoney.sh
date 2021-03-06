#!/bin/sh

#-Script to deal with personal finances.
#-Keeps track of how much money you have by logging how much you spent and received.
#-Money spent is saved as a negative value, while money received is saved as a positive value.

bankfile="$HOME/Documents/bank.csv"
monthly_transactions_file="$HOME/Documents/monthly_transactions.csv"
investments_file="$REPOS/personalspace/investments.csv"
header="date time,amount,transaction type"
group_header="date time,amount,description,type"
monthly_header="type, amount, description"
investment_header="date,amount,description"
default_expense="basic expenses"
default_receive="paycheck"
default_receive_type="general"

currency="R$"

#subject is used to filter emails that contain commands
subject="Whereismymoney"
#email is used to ssh to server and fetch remote commands
email="sua@mae.com"

cur_date=""

addmonthly()
{
	[ ! "$1" ] && echo "Inform type" && return
	t_type="$1"; shift

	[ ! "$1" ] && echo "Inform value" && return
	value="$1"; shift

	[ ! "$1" ] && echo "Inform description" && return
	description="$1"; shift

	[ -e "$monthly_transactions_file" ] || echo "$monthly_header" > "$monthly_transactions_file"

	[ ! "$t_type" = "income" ] && [ ! "$t_type" = "expense" ] &&
			echo "Type not reconized. Valid types are 'income' or 'expense'" && return

	#expenses are negative
	if [ "$t_type" = "income" ]
	then
		value="${value#-}"
	else
		value="-${value#-}"
	fi

	echo "$t_type,$value,$description" >> "$monthly_transactions_file"
}

showmonthly()
{
	[ -e "$monthly_transactions_file" ] ||
		echo "$monthly_header" > "$monthly_transactions_file"

	column -s',' -t < "$monthly_transactions_file"
	showmonthlytotals
}

showmonthlytotals()
{
	[ -e "$monthly_transactions_file" ] ||
		echo "$monthly_header" > "$monthly_transactions_file"

	total_in=$(awk -F',' 'NR>1 && $1 == "income" {total+=$2;}END{print total;}' "$monthly_transactions_file")
	total_ex=$(awk -F',' 'NR>1 && $1 == "expense" {total+=$2;}END{print total;}' "$monthly_transactions_file")
	[ "$total_in" ] && echo "You receive $currency${total_in#-} every month."
	[ "$total_ex" ] && echo "You Spend $currency${total_ex#-} every month."
	[ ! "$total_ex" ] && [ ! "$total_in" ] && echo "No Monthly expenses"
}

showgroups()
{
	path="${bankfile%/*}"
	path="$path/.${0##*/}*"

	for group in $(ls $path)
	do
		groupname=${group#*.*.}
		groupname=${groupname%.*}

		echo "Expenses on: $groupname"
		tail -n +2 $group
		total="$(awk -F',' 'NR>1 {total+=$1;}END{print total}' "$group")"
		echo "Total: $currency${total#-}"
		echo ""
	done
}

filtertransactions()
{
	[ -z "$1" ] && echo "(string) is missing" && echo "usage: ${0##*/} filter (string)"

	column -s',' -t < "$bankfile" |
		grep -r "\(^${header%%,*}\|$1\)" -

	total="$(grep "$1" "$bankfile" | awk -F',' '{total+= $2}END{print total}')"
	echo "total: $currency$total"
}

fetchupdates()
{
	cur_date=$(date "+%Y-%m-%d %H:%M")
	fetchemailtransactions
}

get_email_date()
{
	mailquery="$1"
	email_date=""

	#get date time
	line="$(tail -n 1 "$mailquery")"
	if [ "${line%%:*}" = "date.sent" ]
	then
		# change global date variable to email date so it's saved with the right timestamp
		email_date_time="${line#*: }"
	fi

	#roughly convert date time from utc to correct timezone
	timezone_diff=${email_date_time##*(}
	timezone_diff=${timezone_diff%)}
	operation=${timezone_diff:0:1}
	timezone_diff=${timezone_diff:1}
	timezone_diff_in_seconds=$((timezone_diff * 60))

	seconds_from_epoch="$(date -d "$email_date_time" +%s)"

	if [ "$operation" = '-' ]
	then
		email_date=$(date -d "@$((seconds_from_epoch - timezone_diff_in_seconds))" "+%Y-%m-%d %H:%M")
	else
		email_date=$(date -d "@$((seconds_from_epoch + timezone_diff_in_seconds))" "+%Y-%m-%d %H:%M")
	fi

	echo "$email_date"
}

fetchemailtransactions()
{
	state=0

	cmd=""
	body=""
	amount=""
	t_type=""
	description=""
	errfile="$HOME/.${0##*/}.log"
	mailquery="${0##*/}.mailquery"
	has_command=0

	# query the server for unseen emails with subject=$subject
	# outputs email body and date.sent to a file so line breaks are preserved
	# marks these emails as seen
	# cats the file so we get it's contents locally
	ssh $email "doveadm fetch 'body date.sent' mailbox inbox subject $subject > mailquery &&
		doveadm flags add '\Seen' mailbox inbox unseen subject $subject &&
		doveadm move Trash mailbox inbox seen subject $subject &&
		doveadm move Trash mailbox Sent subject $subject &&
		cat mailquery" > "$mailquery"

	cur_date="$(get_email_date "$mailquery")"
	while IFS= read -r line || [ -n "$line" ]
	do
		case "$state" in
			0) #expect body
				[ "${line%%:*}" = "body" ] && state=1
				;;
			1) #read until find spend or receive
				#concatenate line for future error reporting
				body="$body|$line"
				if [ "${line%% *}" = "Spend" ] ||
					[ "${line%% *}" = "Receive" ]
				then
					has_command=1
					cmd="${line%% *}"
					amount="${line#* }"
					amount="${amount%% *}"
					description="${line#* }"
					description="${description#* }"
					description="${description%,*}"
					t_type="$(echo $line | awk -F',' '{print $2}')"
					t_type="${t_type# }"

					[ "$cmd" = "Spend" ] && logmoneyspent "$amount" "$description" "$t_type"
					[ "$cmd" = "Receive" ] && logmoneyreceived "$amount" "$description" "$t_type"

				elif [ "${line%%:*}" = "date.sent" ]
				then
					[ "$has_command" ] ||
						#read until date and did not get command, something is wrong with the email
						{
							echo "${0##*/} ERROR:"
							echo "    Command not found in email"
							echo "    body: $body"
							echo "====Please do this one manually"
						} >> "$errfile"

					state=0
					body=""
				fi
				;;
		esac

	done < "$mailquery"
	rm "$mailquery"

	[ -e "$errfile" ] &&
		sed 's/|/\n    /g' < "$errfile" > "$errfile.aux" &&
		mv "$errfile.aux" "$errfile" &&
		notify-send "${0##*/} ERROR" "There were errors processing email logged transactions. See $errfile"
}

logtransaction()
{
	[ ! "$1" ] && echo "ERROR: Amount not informed" && return
	[ ! "$2" ] && echo "ERROR: Description not informed" && return

	amount="$1"; shift
	description="$1"; shift
	t_type=""
	[ "$1" ] && t_type="$1" && shift
	[ "$1" ] && cur_date="$1" && shift

	echo "$cur_date,$amount,$description,$t_type" >> "$bankfile"
}

logmoneyspent()
{
	[ ! "$1" ] && echo "ERROR: Amount not informed" && return

	description="$default_expense"
	t_type="$default_expense_type"
	amount="$1"; shift
	#make sure it's a negative
	amount="-${amount#-}"

	[ "$1" ] && description="$1" && shift
	[ "$1" ] && t_type="$1" && shift

	logtransaction "$amount" "$description" "$t_type"
}

logmoneyreceived()
{
	[ ! "$1" ] && echo "ERROR: Amount not informed" && return

	description="$default_receive"
	t_type="$default_receive_type"
	amount="$1"; shift
	#make sure it's a positive
	amount="${amount#-}"

	[ "$1" ] && description="$1" && shift
	[ "$1" ] && t_type="$1" && shift

	logtransaction "$amount" "$description" "$t_type"
}

getbalance()
{

	[ "$1" == "full" ] && file=""

	total="$(awk -F',' 'NR>1 {total+=$2;}END{print total}' "$bankfile")"
	invested="$(awk -F',' 'NR>1 {invested+=$2;}END{print invested}' "$investments_file")"
	[ -z "$invested" ] && invested=0

	if [ "${total%.*}" -lt 0 ]
	then
		echo "You have a debt of -$currency${total#-}"
		[ "$invested" -gt 0 ] &&
			echo "Use your investment of $currency$invested to pay some of it"
	else
		echo "You have $currency$total, of which $currency$invested is invested"
		echo "Usable total: $currency$(python -c "print('{:.2f}'.format($total - $invested))" )"
	fi
}

showbankfile()
{
	cur_date=$(date "+%Y-%m-%d %H:%M")
	cur_month=${cur_date%-*}
	header_beginning=${header%%,*}

	if [ "$1" = "full" ]
	then
		column -s',' -t < "$bankfile"
	else
		column -s',' -t < "$bankfile" |
			grep -r "\(^$header_beginning\|^$cur_month\)" -
	fi

	getbalance
}

addgrouptransaction()
{
	group="$1"; shift
	amount="$1"; shift
	description="$1"; shift
	tag="$1"; shift
	cur_date=$(date "+%Y-%m-%d %H:%M")

	[ ! "$group" ] || [ ! "$amount" ] || [ ! "$description" ] || [ ! "$tag" ] &&
		echo "usage: ${0##*/} group (group name) ([-] number) (description) (tag)" &&
		return

	path="${bankfile%/*}"
	groupfile="$path/.${0##*/}.$group.csv"
	[ -e "$groupfile" ] ||
		echo "$group_header" > "$groupfile"

	echo "$cur_date,$amount,$description,$tag" >> "$groupfile"
}

loggrouptransactions()
{
	group="$1"; shift

	[ ! "$group" ] &&
		echo "usage: ${0##*/} log (group name)" &&
		return

	cur_date=$(date "+%Y-%m-%d %H:%M")

	path="${bankfile%/*}"
	groupfile="$path/.${0##*/}.$group.csv"
	[ ! -e "$groupfile" ] && echo "group does not exist" && return

	while IFS= read -r transaction || [ -n "$transaction" ]
	do
		[ "$transaction" = "$group_header" ] && continue
		transaction_date=${transaction%%,*}
		amount=${transaction#*,}
		amount=${amount%%,*}
		desc=${transaction%,*}
		desc=${desc##*,}
		type=${transaction##*,}

		logtransaction "$amount" "$desc" "$type" "$transaction_date"
	done < "$groupfile"

	#clear groupfile
	echo "$group_header" > "$groupfile"
}

loginvestment()
{
	investment="$1"
	description="$2"

	if [ -z "$1" ] || [ -z "$2" ]
	then
		echo "usage: ${0##*/} invest (amount) (description)"
		return
	fi

	[ -e "$investments_file" ] || echo "$investment_header" > "$investments_file"

	echo "$cur_date,$investment,$description" >> "$investments_file"
}

uninvest()
{
	withdraw="$1"
	description="$2"
	if [ -z "$1" ] || [ -z "$2" ]
	then
		echo "usage: ${0##*/} uninvest (amount) (description)"
		return
	fi

	[ ! -e "$investments_file" ] && echo "Error: Investments file not found" && return

	echo "$cur_date,-${withdraw#-},$description" >> "$investments_file"
}

showwrapper()
{
	case "$1" in
		invested)
			showinvestments
			;;
		groups)
			showgroups
			;;
		types)
			showtypes
			;;
		typetotal)
			showtypetotal "$2"
			;;
		full)
			showbankfile "full"
			;;
		*)
			showbankfile
			;;
	esac
}

showinvestments()
{
	column -s',' -t < "$investments_file"
	total="$(awk -F',' 'NR>1 {total+=$2}END{print total}' "$investments_file")"
	echo "Total invested: $currency$total"
}

showtypes()
{
	echo "Registered transaction types:"
	awk -F',' 'NR>1 {print "\t+ "$4}' $bankfile | sort -u
}

showtypetotal()
{
	[ -z "$1" ] && echo "Type not informed" && return

	t_type="$1"; shift

	total="$(awk -F',' 'NR>1 && $4=="'"$t_type"'" {total+=$2;}END{print total}' "$bankfile")"

	if [ "${total%%.*}" -lt 1 ]
	then
		echo "You spent $currency${total#-} with $t_type"
	else
		echo "You received $currency${total} with $t_type"
	fi
}

editfile()
{
	file="$bankfile"

	if [ "$1" = "invest" ]
	then
			file="$investments_file"
	else
		[ "$1" ] && path="${bankfile%/*}" && file="$path/.${0##*/}.$1.csv"
	fi

	"$EDITOR" "$file"
}

#RUNNING
[ -e "$bankfile" ] ||
	echo "$header" > "$bankfile"

[ "$1" ] && arg="$1" && shift
case "$arg" in
	balance)
		getbalance
		;;
	edit)
		editfile "$1"
		;;
	filter)
		filtertransactions "$1"
		;;
	fetch)
		fetchupdates
		;;
	invest)
		cur_date=$(date "+%Y-%m-%d %H:%M")
		loginvestment "$1" "$2"
		;;
	uninvest)
		cur_date=$(date "+%Y-%m-%d %H:%M")
		uninvest "$1" "$2"
		;;
	group)
		addgrouptransaction "$1" "$2" "$3" "$4"
		;;
	log)
		loggrouptransactions "$1"
		;;
	receive)
		cur_date=$(date "+%Y-%m-%d %H:%M")
		logmoneyreceived "$1" "$2" "$3"
		;;
	show)
		showwrapper "$1" "$2"
		;;
	spend)
		cur_date=$(date "+%Y-%m-%d %H:%M")
		logmoneyspent "$1" "$2" "$3"
		;;
	*)
		echo "usage: ${0##*/} ( command )"
		echo "commands:"
		echo "		edit: Opens the bankfile with EDITOR"
		echo "		fetch: Fetches transactions registered by email"
		echo "		filter (string): Lists expenses containing (string)"
		echo "		group (group name) ([-|+] number) (description) (tag): adds a transaction to the specified group"
		echo "		invest (amount)  (description): logs an investment"
		echo "		uninvest (amount)  (description): withdraw from investments"
		echo "		log (group): updates the bankfile with the speficied group transactions."
		echo "		receive (number) [ type ] [ tag ]: Register you received (number) of (type) of tag (tag)"
		echo "		spend (number) [ type ]: Register an expense of number and type (if informed)"
		echo "		show [ full/groups/types/typetotal (type)/invested ]: shows data from the bank file filtered"
		;;
esac
