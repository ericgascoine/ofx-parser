require 'rubygems'
require 'hpricot'
require 'time'
require 'date'

%w(ofx mcc).each do |fn|
  # require File.dirname(__FILE__) + "/#{fn}"
end

module OfxParser
  VERSION = '1.1.0'

  class OfxParser

    # Creates and returns an Ofx instance when given a well-formed OFX document,
    # complete with the mandatory key:pair header.
    def self.parse(ofx)
      ofx = ofx.respond_to?(:read) ? ofx.read.to_s : ofx.to_s

      return Ofx.new if ofx == ""

      header, body = pre_process(ofx)

      ofx_out = parse_body(body)
      ofx_out.header = header
      ofx_out
    end

    # Designed to make the main OFX body parsable. This means adding closing tags
    # to the SGML to make it parsable by hpricot.
    #
    # Returns an array of 2 elements:
    # * header as a hash,
    # * body as an evily pre-processed string ready for parsing by hpricot.
    def self.pre_process(ofx)
      header, body = ofx.split(/\n{2,}|:?<OFX>/, 2)

      header = Hash[*header.gsub(/^\r?\n+/,'').split(/\r\n/).collect do |e|
        e.split(/:/,2)
      end.flatten]

      body.gsub!(/>\s+</m, '><')
      body.gsub!(/\s+</m, '<')
      body.gsub!(/>\s+/m, '>')
      body.gsub!(/<([^>]+?)>([^<]+)/m, '<\1>\2</\1>')

      [header, body]
    end

    # Takes an OFX datetime string of the format:
    # * YYYYMMDDHHMMSS.XXX[gmt offset:tz name]
    # * YYYYMMDD
    # * YYYYMMDDHHMMSS
    # * YYYYMMDDHHMMSS.XXX
    #
    # Returns a DateTime object. Milliseconds (XXX) are ignored.
    def self.parse_datetime(date)
      DateTime.parse date
    end

  private
    def self.parse_body(body)
      doc = Hpricot.XML(body)

      ofx = Ofx.new

      ofx.sign_on = build_signon((doc/"SIGNONMSGSRSV1/SONRS"))
      ofx.signup_account_info = build_info((doc/"SIGNUPMSGSRSV1/ACCTINFOTRNRS"))

      # Bank Accounts
      bank_fragment = (doc/"BANKMSGSRSV1/STMTTRNRS")
      ofx.bank_accounts = bank_fragment.collect do |fragment|
        build_bank(fragment)
      end

      # Credit Cards
      credit_card_fragment = (doc/"CREDITCARDMSGSRSV1/CCSTMTTRNRS")
      ofx.credit_accounts = credit_card_fragment.collect do |fragment|
        build_credit(fragment)
      end


      # Securities
      security_fragment = (doc/"SECLISTMSGSRSV1/SECLIST/STOCKINFO")
      ofx.securities = security_fragment.collect do |fragment|
        build_stock_info(fragment)
      end

      # Investments (?)
      investment_account_fragment = (doc/"INVSTMTMSGSRSV1/INVSTMTTRNRS/INVSTMTRS")
      ofx.investment_accounts = investment_account_fragment.collect do |fragment|
        build_investment_account(fragment)
      end


      ofx
    end

    def self.build_signon(doc)
      sign_on = SignOn.new
      sign_on.status = build_status((doc/"STATUS"))
      sign_on.date = parse_datetime((doc/"DTSERVER").inner_text)
      sign_on.language = (doc/"LANGUAGE").inner_text

      sign_on.institute = Institute.new
      sign_on.institute.name = ((doc/"FI")/"ORG").inner_text
      sign_on.institute.id = ((doc/"FI")/"FID").inner_text
      sign_on
    end

    def self.build_info(doc)
      account_infos = []

      (doc/"ACCTINFO").each do |info_doc|
        acc_info = AccountInfo.new
        acc_info.desc = (info_doc/"DESC").inner_text
        acc_info.number = (info_doc/"ACCTID").first.inner_text
        acc_info.bank_id = (info_doc/"BANKID").first.inner_text unless (info_doc/"BANKID").empty?
        acc_info.type = (info_doc/"ACCTTYPE").first.inner_text unless (info_doc/"ACCTTYPE").empty?
        account_infos << acc_info
      end

      account_infos
    end

    def self.build_bank(doc)
      acct = BankAccount.new

      acct.transaction_uid = (doc/"TRNUID").inner_text.strip
      acct.number = (doc/"STMTRS/BANKACCTFROM/ACCTID").inner_text
      acct.routing_number = (doc/"STMTRS/BANKACCTFROM/BANKID").inner_text
      acct.type = (doc/"STMTRS/BANKACCTFROM/ACCTTYPE").inner_text.strip
      acct.balance = (doc/"STMTRS/LEDGERBAL/BALAMT").inner_text
      acct.balance_date = parse_datetime((doc/"STMTRS/LEDGERBAL/DTASOF").inner_text)

      statement = Statement.new
      statement.currency = (doc/"STMTRS/CURDEF").inner_text
      statement.start_date = parse_datetime((doc/"STMTRS/BANKTRANLIST/DTSTART").inner_text)
      statement.end_date = parse_datetime((doc/"STMTRS/BANKTRANLIST/DTEND").inner_text)
      acct.statement = statement

      statement.transactions = (doc/"STMTRS/BANKTRANLIST/STMTTRN").collect do |t|
        build_transaction(t)
      end

      acct
    end

    def self.build_credit(doc)
      acct = CreditAccount.new

      acct.number = (doc/"CCSTMTRS/CCACCTFROM/ACCTID").inner_text
      acct.transaction_uid = (doc/"TRNUID").inner_text.strip
      acct.balance = (doc/"CCSTMTRS/LEDGERBAL/BALAMT").inner_text
      acct.balance_date = parse_datetime((doc/"CCSTMTRS/LEDGERBAL/DTASOF").inner_text)
      acct.remaining_credit = (doc/"CCSTMTRS/AVAILBAL/BALAMT").inner_text
      acct.remaining_credit_date = parse_datetime((doc/"CCSTMTRS/AVAILBAL/DTASOF").inner_text)

      statement = Statement.new
      statement.currency = (doc/"CCSTMTRS/CURDEF").inner_text
      statement.start_date = parse_datetime((doc/"CCSTMTRS/BANKTRANLIST/DTSTART").inner_text)
      statement.end_date = parse_datetime((doc/"CCSTMTRS/BANKTRANLIST/DTEND").inner_text)
      acct.statement = statement

      statement.transactions = (doc/"CCSTMTRS/BANKTRANLIST/STMTTRN").collect do |t|
        build_transaction(t)
      end

      acct
    end

    # for credit and bank transactions.
    def self.build_transaction(t)
      transaction = Transaction.new
      transaction.type = (t/"TRNTYPE").inner_text
      transaction.date = parse_datetime((t/"DTPOSTED").inner_text)
      transaction.amount = (t/"TRNAMT").inner_text
      transaction.fit_id = (t/"FITID").inner_text
      transaction.payee = (t/"PAYEE").inner_text + (t/"NAME").inner_text
      transaction.memo = (t/"MEMO").inner_text
      transaction.sic = (t/"SIC").inner_text
      transaction.check_number = (t/"CHECKNUM").inner_text unless (t/"CHECKNUM").inner_text.empty?
      transaction
    end


    def self.build_investment(doc)

    end

    def self.build_status(doc)
      status = Status.new
      status.code = (doc/"CODE").inner_text
      status.severity = (doc/"SEVERITY").inner_text
      status.message = (doc/"MESSAGE").inner_text
      status
    end

    def self.build_security_id(doc)
      security_id = SecurityId.new
      security_id.unique_id = (doc/"UNIQUEID").inner_text
      security_id.unique_id_type = (doc/"UNIQUEIDTYPE").inner_text
      security_id
    end

    def self.build_security_info(doc)
      security_info = SecurityInfo.new
      security_info.security_id = build_security_id (doc/"SECID")
      security_info.ticker = (doc/"TICKER").inner_text
      security_info.fi_id = (doc/"FIID").inner_text
      security_info.rating = (doc/"RATING").inner_text
      security_info.unit_price = (doc/"UNITPRICE").inner_text
      security_info.date_of_unit_price = parse_datetime((doc/"DTASOF").inner_text) unless ((doc/"DTASOF").inner_text).empty?
      security_info.currency = (doc/"CURRENCY").inner_text
      security_info.memo = (doc/"MEMO").inner_text
      security_info
    end

    def self.build_stock_info(doc)
      stock_info = StockInfo.new
      stock_info.security_info = build_security_info(doc/"SECINFO")
      stock_info.stock_type = (doc/"STOCKTYPE").inner_text
      stock_info.yeild = (doc/"YIELD").inner_text
      stock_info.yeild_as_of_date = parse_datetime((doc/"DTYEILDASOF").inner_text) unless ((doc/"DTYEILDASOF").inner_text).empty?
      stock_info.asset_class = (doc/"ASSETCLASS").inner_text
      stock_info.f1_asset_class = (doc/"F1ASSETCLASS").inner_text
      stock_info
    end

    def self.build_investment_account(doc)
      acct = InvestmentAccount.new
      acct.broker_id=(doc/"INVACCTFROM/BROKERID").inner_text
      acct.account_id=(doc/"INVACCTFROM/ACCTID").inner_text
      acct.availcash = (doc/"INVBAL/AVAILCASH").inner_text
      acct.margin_balance = (doc/"INVBAL/MARGINBALANCE").inner_text
      acct.short_balance = (doc/"INVBAL/SHORTBALANCE").inner_text

      statement = Statement.new
      acct.statement=statement

      #-----------------------------------------------------------------------
      # Ideally we wouldn't need 2 separate classes for different types of positions/transactions.
      # Need to find some way to parse informaton based on "POS****" or "BUY****"

      statement.stock_positions = (doc/"INVPOSLIST/POSSTOCK").collect do |p|
        build_stock_position(p)
      end

      statement.opt_positions = (doc/"INVPOSLIST/POSOPT").collect do |p|
        build_opt_position(p)
      end

      statement.stock_transactions = (doc/"INVTRANLIST/BUYSTOCK").collect do |t|
        build_stock_transactions(t)
      end
      acct
    end

    def self.build_stock_transactions(t)
      stock_transaction = Stock_Transaction.new
      stock_transaction.transid = (t/"INVBUY/INVTRAN/FITID").inner_text
      stock_transaction.tradedate = parse_datetime((t/"INVBUY/INVTRAN/DTTRADE").inner_text) unless (t/"INVBUY/INVTAN/DTTRADE").inner_text.empty?
      stock_transaction.settledate = parse_datetime((t/"INVBUY/INVTRAN/DTSETTLE").inner_text) unless (t/"INVBUY/INVTAN/DTSETTLE").inner_text.empty?
      stock_transaction.uniqueid = (t/"INVBUY/SECID/UNIQUEID").inner_text
      stock_transaction.uniqueid_type = (t/"INVBUY/SECID/UNIQUEIDTYPE").inner_text
      stock_transaction.units = (t/"INVBUY/UNITS").inner_text
      stock_transaction.unitprice = (t/"INVBUY/UNITPRICE").inner_text
      stock_transaction.commission = (t/"INVBUY/UNITPRICE").inner_text
      stock_transaction.total = (t/"INVBUY/TOTAL").inner_text
      stock_transaction.subacctsec = (t/"INVBUY/SUBACCTSEC").inner_text
      stock_transaction.subacctfund = (t/"INVBUY/SUBACCTFUND").inner_text
      stock_transaction.type = (t/"BUYTYPE").inner_text
      stock_transaction
    end


    def self.build_stock_position(p)
      stock_position = Stock_Position.new
      stock_position.uniqueid = (p/"INVPOS/SECID/UNIQUEID").inner_text
      stock_position.uniqueid_type = (p/"INVPOS/SECID/UNIQUEIDTYPE").inner_text
      stock_position.heldinacct = (p/"INVPOS/HELDINACCT").inner_text
      stock_position.type = (p/"INVPOS/POSTYPE").inner_text
      stock_position.units = (p/"INVPOS/UNITS").inner_text
      stock_position.unitprice = (p/"INVPOS/UNITPRICE").inner_text
      stock_position.pricedate = parse_datetime((p/"INVPOS/DTPRICEASOF").inner_text)
      stock_position.memo = (p/"INVPOS/MEMO").inner_text
      stock_position
    end

    def self.build_opt_position(p)
      opt_position = Opt_Position.new
      opt_position.uniqueid = (p/"INVPOS/SECID/UNIQUEID").inner_text
      opt_position.uniqueid_type = (p/"INVPOS/SECID/UNIQUEIDTYPE").inner_text
      opt_position.heldinacct = (p/"INVPOS/HELDINACCT").inner_text
      opt_position.type = (p/"INVPOS/POSTYPE").inner_text
      opt_position.units = (p/"INVPOS/UNITS").inner_text
      opt_position.unitprice = (p/"INVPOS/UNITPRICE").inner_text
      opt_position.mktval = (p/"INVPOS/MKTVAL").inner_text
      opt_position.pricedate = parse_datetime((p/"INVPOS/DTPRICEASOF").inner_text)
      opt_position.memo = (p/"INVPOS/MEMO").inner_text
      opt_position
    end
  end
end



