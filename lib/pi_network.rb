gem_dir = Gem::Specification.find_by_name("pi_network").gem_dir
require "#{gem_dir}/lib/errors"

class PiNetwork
  require 'faraday'
  require 'json'
  require 'stellar-sdk'

  attr_reader :api_key
  attr_reader :client
  attr_reader :account
  attr_reader :base_url
  attr_reader :from_address

  def initialize(api_key, wallet_private_key, options = {})
    validate_private_seed_format!(wallet_private_key)
    @api_key = api_key
    @account = load_account(wallet_private_key)
    @base_url = options[:base_url] || "https://api.minepi.com"

    @open_payments = {}
  end

  def get_payment(payment_id)
    response = Faraday.get(
      base_url + "/v2/payments/#{payment_id}",
      {},
      http_headers,
    )

    if response.status == 404
      raise Errors::PaymentNotFoundError.new("Payment not found", payment_id)
    end

    handle_http_response(response, "An unknown error occurred while fetching the payment")
  end

  def create_payment(payment_data)
    validate_payment_data!(payment_data, {amount: true, memo: true, metadata: true, uid: true})

    request_body = {
      payment: payment_data,
    }

    response = Faraday.post(
      base_url + "/v2/payments",
      request_body.to_json,
      http_headers,
    )

    parsed_response = handle_http_response(response, "An unknown error occurred while creating a payment")
    
    identifier = parsed_response["identifier"]
    @open_payments[identifier] = parsed_response

    return identifier
  end

  def submit_payment(payment_id)
    payment = @open_payments[payment_id]

    if payment.nil? || payment["identifier"] != payment_id
      payment = get_payment(payment_id)
      txid = payment["transaction"]["txid"]
      raise Errors::TxidAlreadyLinkedError.new("This payment already has a linked txid", payment_id, txid) if txid.present?
    end

    set_horizon_client(payment["network"])
    @from_address = payment["from_address"]

    transaction_data = {
      amount: payment["amount"],
      identifier: payment["identifier"],
      recipient: payment["to_address"]
    }

    transaction = build_a2u_transaction(transaction_data)
    txid = submit_transaction(transaction)

    @open_payments.delete(payment_id)

    return txid
  end

  def complete_payment(identifier, txid)
    body = {"txid": txid}

    response = Faraday.post(
      base_url + "/v2/payments/#{identifier}/complete",
      body.to_json,
      http_headers
    )

    @open_payments.delete(identifier)
    handle_http_response(response, "An unknown error occurred while completing the payment")
  end

  def cancel_payment(identifier)
    response = Faraday.post(
      base_url + "/v2/payments/#{identifier}/cancel",
      {}.to_json,
      http_headers,
    )

    @open_payments.delete(identifier)
    handle_http_response(response, "An unknown error occurred while cancelling the payment")
  end

  def get_incomplete_server_payments
    response = Faraday.get(
      base_url + "/v2/payments/incomplete_server_payments",
      {},
      http_headers,
    )

    res = handle_http_response(response, "An unknown error occurred while fetching incomplete payments")
    res["incomplete_server_payments"]
  end

  private

  def http_headers
    return nil if @api_key.nil?

    {
      "Authorization": "Key #{@api_key}",
      "Content-Type": "application/json"
    }
  end

  def handle_http_response(response, unknown_error_message = "An unknown error occurred while making an API request")
    unless response.status == 200
      error_message = JSON.parse(response.body).dig("error_message") rescue unknown_err_message
      raise Errors::APIRequestError.new(error_message, response.status, response.body)
    end

    begin
      parsed_response = JSON.parse(response.body)
      return parsed_response
    rescue StandardError => err
      error_message = "Failed to parse response body"
      raise Errors::APIRequestError.new(error_message, response.status, response.body)
    end
  end

  def set_horizon_client(network)
    host = network == "Pi Network" ? "api.mainnet.minepi.com" : "api.testnet.minepi.com"
    horizon = network == "Pi Network" ? "https://api.mainnet.minepi.com" : "https://api.testnet.minepi.com"
    client = Stellar::Client.new(host: host, horizon: horizon)
    Stellar::default_network = network

    @client = client
  end

  def load_account(private_seed)
    account = Stellar::Account.from_seed(private_seed)
  end

  def build_a2u_transaction(transaction_data)
    raise StandardError.new("You should use a private seed of your app wallet!") if self.from_address != self.account.address
    
    validate_payment_data!(transaction_data, {amount: true, identifier: true, recipient: true})

    amount = Stellar::Amount.new(transaction_data[:amount])
    # TODO: get this from horizon
    fee = 100000 # 0.01π
    recipient = Stellar::KeyPair.from_address(transaction_data[:recipient])
    memo = Stellar::Memo.new(:memo_text, transaction_data[:identifier])

    payment_operation = Stellar::Operation.payment({
      destination: recipient,
      amount: amount.to_payment
    })
    
    my_public_key = self.account.address
    sequence_number = self.client.account_info(my_public_key).sequence.to_i
    transaction_builder = Stellar::TransactionBuilder.new(
      source_account: self.account.keypair,
      sequence_number: sequence_number + 1,
      base_fee: fee,
      memo: memo
    )

    transaction = transaction_builder.add_operation(payment_operation).set_timeout(180000).build
  end

  def submit_transaction(transaction)
    envelope = transaction.to_envelope(self.account.keypair)
    response = self.client.submit_transaction(tx_envelope: envelope)
    txid = response._response.body["id"]
  end

  def validate_payment_data!(data, options = {})
    raise ArgumentError.new("Missing amount") if options[:amount] && !data[:amount].present?
    raise ArgumentError.new("Missing memo") if options[:memo] && !data[:memo].present?
    raise ArgumentError.new("Missing metadata") if options[:metadata] && !data[:metadata].present?
    raise ArgumentError.new("Missing uid") if options[:uid] && !data[:uid].present?
    raise ArgumentError.new("Missing identifier") if options[:identifier] && !data[:identifier].present?
    raise ArgumentError.new("Missing recipient") if options[:recipient] && !data[:recipient].present?
  end

  def validate_private_seed_format!(seed)
    raise StandardError.new("Private Seed should start with \"S\"") unless seed.upcase.starts_with?("S")
    raise StandardError.new("Private Seed should be 56 characters") unless seed.length == 56
  end
end