#!/bin/bash


# Retrieves values and attempts to compare values to an expected result (with retries).
# @param {string} A text query that respect the appropriate syntax
# @return
#	1 If the query is empty
#	2 If it does not respect the syntax
#	3 If the value could not be verified after all the attempts
#	0 Otherwise
try() {

	# The syntax to use
	regex="at +most +([0-9]+) +times +every +([0-9]+)s +to +get +([a-z]+) +named +'([^']+)' +and +verify +that +'([^']+)' +is +'([^']+)'"

	# Concatenate all the arguments into a single string
	IFS=' '
	exp="$*"
	
	# Trim the expression
	exp=$(trim "$exp")

	# Make the regular expression case-insensitive
	shopt -s nocasematch;

	# Verify the expression and use it to build a request
	if [[ "$exp" == "" ]]; then
		echo "An empty expression was not expected."
		return 1
	
	elif [[ "$exp" =~ $regex ]]; then
		
		# Extract parameters
		times="${BASH_REMATCH[1]}"
		delay="${BASH_REMATCH[2]}"
		resource=$(to_lower_case "${BASH_REMATCH[3]}")
		name="${BASH_REMATCH[4]}"
		property="${BASH_REMATCH[5]}"
		expected_value=$(to_lower_case "${BASH_REMATCH[6]}")
		
		# Prevent line breaks from being removed in command results
		IFS=""
		
		echo "Valid expression. Verification in progress..."
		code=0
		for ((i=1; i<=$times; i++)); do

			# Verify the value
			verify_value $property $expected_value $resource $name
			code=$?
	
			# Break the loop prematurely?
			if [[ "$code" == "0" ]]; then
				break
			elif [[ "$i" != "1" ]]; then
				code=3
				sleep $delay
			else
				code=3
			fi
		done
		
		## Error code
		return $code

	else
		echo "Invalid expression: it does not respect the expected syntax."
		return 2
	fi
}


# Retrieves values and attempts to compare values to an expected result (without any retry).
# @param {string} A text query that respect one of the supported syntaxes
# @return
#	1 If the query is empty
#	2 If it does not respect the syntax
#	3 If the elements count is incorrect
#	0 Otherwise
verify() {

	# The syntaxes that can be used
	regex_count_is="there +is +(0|1) +([a-z]+) +named +'([^']+)'"
	regex_count_are="there +are +([0-9]+) +([a-z]+) +named +'([^']+)'"
	regex_verify="'([^']+)' +is +'([^']+)' +for +([a-z]+) +named +'([^']+)'"

	# Concatenate all the arguments into a single string
	IFS=' '
	exp="$*"
	
	# Trim the expression
	exp=$(trim "$exp")

	# Make the regular expression case-insensitive
	shopt -s nocasematch;

	# Verify the expression and use it to build a request
	if [[ "$exp" == "" ]]; then
		echo "An empty expression was not expected."
		return 1
	
	elif [[ "$exp" =~ $regex_count_is ]] || [[ "$exp" =~ $regex_count_are ]]; then
		card="${BASH_REMATCH[1]}"
		resource=$(to_lower_case "${BASH_REMATCH[2]}")
		name="${BASH_REMATCH[3]}"

		echo "Valid expression. Verification in progress..."
		query=$(build_k8s_request "")
		result=$(eval $DETIK_CLIENT_NAME get $resource $query | grep $name | tail -n +1 | wc -l)

		if [[ "$DETIK_DEBUG" != "" ]]; then
			exec 6<> "$DETIK_DEBUG"

			echo "---------" >&6
			echo "$BATS_TEST_FILENAME" >&6
			echo "$BATS_TEST_DESCRIPTION" >&6
			echo "" >&6
			echo "Client query:" >&6
			echo "$DETIK_CLIENT_NAME get $resource $query" >&6
			echo "" >&6
			echo "Result:" >&6
			echo "$result" >&6
		
			exec 6>&-
		fi

		if [[ "$result" == "$card" ]]; then
			echo "Found $result $resource named $name (as expected)."
		else
			echo "Found $result $resource named $name (instead of $card expected)."
			return 3
		fi
	
	elif [[ "$exp" =~ $regex_verify ]]; then
		property="${BASH_REMATCH[1]}"
		expected_value="${BASH_REMATCH[2]}"
		resource=$(to_lower_case "${BASH_REMATCH[3]}")
		name="${BASH_REMATCH[4]}"
		
		echo "Valid expression. Verification in progress..."
		verify_value $property $expected_value $resource $name
		
		if [[ "$?" != "0" ]]; then
			return 3
		fi

	else
		echo "Invalid expression: it does not respect the expected syntax."
		return 2
	fi
}


# Verifies the value of a column for a set of elements.
# @param {string} A K8s column or one of the supported aliases.
# @return the number of elements with the wrong value
verify_value() {

	# Make the parameters readable
	property="$1"
	expected_value=$(to_lower_case "$2")
	resource="$3"
	name="$4"

	# List the items and remove the first line (the one that contains the column names)
	query=$(build_k8s_request $property)
	result=$(eval $DETIK_CLIENT_NAME get $resource $query | grep $name | tail -n +1)

	# Debug?
	if [[ "$DETIK_DEBUG" != "" ]]; then
		exec 6<> "$DETIK_DEBUG"

		echo "---------" >&6
		echo "$BATS_TEST_FILENAME" >&6
		echo "$BATS_TEST_DESCRIPTION" >&6
		echo "" >&6
		echo "Client query:" >&6
		echo "$DETIK_CLIENT_NAME get $resource $query" >&6
		echo "" >&6
		echo "Result:" >&6
		echo "$result" >&6
		
		exec 6>&-
	fi
	
	# Is the result empty?
	if [[ "$result" == "" ]]; then
		echo "No resource of type '$resource' was found with the name '$name'."
	fi
			
	# Verify the result
	IFS=$'\n'
	invalid=0
	for line in $result; do
				
		# Keep the second column (property to verify)
		# and put it in lower case
		value=$(to_lower_case "$line" | awk '{ print $2 }')
		element=$(echo "$line" | awk '{ print $1 }')
		if [[ "$value" != "$expected_value" ]]; then
			echo "Current value for $element is $value..."
			invalid=$((invalid + 1))
		else
			echo "$element has the right value ($value)."
		fi
	done
	
	return $invalid
}


# Builds the request for the get operation of the K8s client.
# @param {string} A K8s column or one of the supported aliases.
# @return 0
build_k8s_request() {

	req="-o custom-columns=NAME:.metadata.name"
	if [[ "$1" == "status" ]]; then
		req="$req,PROP:.status.phase"
	elif [[ "$1" == "port" ]]; then
		req="$req,PROP:.spec.ports[*].port"
	elif [[ "$1" == "targetPort" ]]; then
		req="$req,PROP:.spec.ports[*].targetPort"
	elif [[ "$1" != "" ]]; then
		req="$req,PROP:$1"
	fi
	
	echo $req
}


# Prints a string in lower case.
# @param {string} The string.
# @return 0
to_lower_case() {
	echo "$1" | tr '[:upper:]' '[:lower:]'
}


# Trims a text.
# @param {string} The string.
# @return 0
trim() {
	echo $1 | sed -e 's/^[[:space:]]*([^[[:space:]]].*[^[[:space:]]])[[:space:]]*$/$1/'
}
