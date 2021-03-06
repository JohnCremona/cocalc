###
User sign in

Throttling policy:  Itbasically like this, except we reset the counters
each minute and hour, so a crafty attacker could get twice as many tries by finding the
reset interval and hitting us right before and after.  This is an acceptable tradeoff
for making the data structure trivial.

  * POLICY 1: A given email address is allowed at most 3 failed login attempts per minute.
  * POLICY 2: A given email address is allowed at most 30 failed login attempts per hour.
  * POLICY 3: A given ip address is allowed at most 10 failed login attempts per minute.
  * POLICY 4: A given ip address is allowed at most 50 failed login attempts per hour.
###

async                = require('async')

message              = require('smc-util/message')
misc                 = require('smc-util/misc')
{required, defaults} = misc

auth                 = require('./auth')

sign_in_fails =
    email_m : {}
    email_h : {}
    ip_m    : {}
    ip_h    : {}

clear_sign_in_fails_m = () ->
    sign_in_fails.email_m = {}
    sign_in_fails.ip_m = {}

clear_sign_in_fails_h = () ->
    sign_in_fails.email_h = {}
    sign_in_fails.ip_h = {}

_sign_in_fails_intervals = undefined

record_sign_in_fail = (opts) ->
    {email, ip, logger} = defaults opts,
        email  : required
        ip     : required
        logger : undefined
    if not _sign_in_fails_intervals?
        # only start clearing if there has been a failure...
        _sign_in_fails_intervals = [setInterval(clear_sign_in_fails_m, 60000), setInterval(clear_sign_in_fails_h, 60*60000)]

    logger?("WARNING: record_sign_in_fail(#{email}, #{ip})")
    s = sign_in_fails
    if not s.email_m[email]?
        s.email_m[email] = 0
    if not s.ip_m[ip]?
        s.ip_m[ip] = 0
    if not s.email_h[email]?
        s.email_h[email] = 0
    if not s.ip_h[ip]?
        s.ip_h[ip] = 0
    s.email_m[email] += 1
    s.email_h[email] += 1
    s.ip_m[ip] += 1
    s.ip_h[ip] += 1

sign_in_check = (opts) ->
    {email, ip} = defaults opts,
        email : required
        ip    : required
    s = sign_in_fails
    if s.email_m[email] > 3
        # A given email address is allowed at most 3 failed login attempts per minute
        return "Wait a minute, then try to login again.  If you can't remember your password, reset it or email help@sagemath.com."
    if s.email_h[email] > 30
        # A given email address is allowed at most 30 failed login attempts per hour.
        return "Wait an hour, then try to login again.  If you can't remember your password, reset it or email help@sagemath.com."
    if s.ip_m[ip] > 10
        # A given ip address is allowed at most 10 failed login attempts per minute.
        return "Wait a minute, then try to login again.  If you can't remember your password, reset it or email help@sagemath.com."
    if s.ip_h[ip] > 50
        # A given ip address is allowed at most 50 failed login attempts per hour.
        return "Wait an hour, then try to login again.  If you can't remember your password, reset it or email help@sagemath.com."
    return false

exports.sign_in = (opts) ->
    {client, mesg} = opts = defaults opts,
        client   : required
        mesg     : required
        logger   : undefined
        database : required
        host     : undefined
        port     : undefined
        cb       : undefined

    if opts.logger?
        dbg = (m) ->
            opts.logger.debug("sign_in(#{mesg.email_address}): #{m}")
        dbg()
    else
        dbg = ->
    tm = misc.walltime()

    sign_in_error = (error) ->
        dbg("sign_in_error -- #{error}")
        exports.record_sign_in
            database      : opts.database
            ip_address    : client.ip_address
            successful    : false
            email_address : mesg.email_address
            account_id    : account?.account_id
        client.push_to_client(message.sign_in_failed(id:mesg.id, email_address:mesg.email_address, reason:error))
        opts.cb?(error)

    if not mesg.email_address
        sign_in_error("Empty email address.")
        return

    if not mesg.password
        sign_in_error("Empty password.")
        return

    mesg.email_address = misc.lower_email_address(mesg.email_address)

    m = sign_in_check
        email : mesg.email_address
        ip    : client.ip_address
    if m
        sign_in_error("sign_in_check fail(ip=#{client.ip_address}): #{m}")
        return

    signed_in_mesg = undefined
    account = undefined
    async.series([
        (cb) ->
            dbg("get account and check credentials")
            # NOTE: Despite people complaining, we do give away info about whether
            # the e-mail address is for a valid user or not.
            # There is no security in not doing this, since the same information
            # can be determined via the invite collaborators feature.
            opts.database.get_account
                email_address : mesg.email_address
                columns       : ['password_hash', 'account_id', 'passports']
                cb            : (err, _account) ->
                    account = _account; cb(err)
        (cb) ->
            dbg("got account; now checking if password is correct...")
            auth.is_password_correct
                database      : opts.database
                account_id    : account.account_id
                password      : mesg.password
                password_hash : account.password_hash
                cb            : (err, is_correct) ->
                    if err
                        cb("Error checking correctness of password -- #{err}")
                        return
                    if not is_correct
                        if not account.password_hash
                            cb("The account #{mesg.email_address} exists but doesn't have a password. Either set your password by clicking 'Forgot Password?' or log in using #{misc.keys(account.passports).join(', ')}.  If that doesn't work, email help@sagemath.com and we will sort this out.")
                        else
                            cb("Incorrect password for #{mesg.email_address}.  You can reset your password by clicking the 'Forgot Password?' link.   If that doesn't work, email help@sagemath.com and we will sort this out.")
                    else
                        cb()
        # remember me
        (cb) ->
            if mesg.remember_me
                dbg("remember_me -- setting the remember_me cookie")
                signed_in_mesg = message.signed_in
                    id            : mesg.id
                    account_id    : account.account_id
                    email_address : mesg.email_address
                    remember_me   : false
                    hub           : opts.host + ':' + opts.port
                client.remember_me
                    account_id    : signed_in_mesg.account_id
                    email_address : signed_in_mesg.email_address
                    cb            : cb
            else
                cb()
    ], (err) ->
        if err
            dbg("send error to user (in #{misc.walltime(tm)}seconds) -- #{err}")
            sign_in_error(err)
            opts.cb?(err)
        else
            dbg("user got signed in fine (in #{misc.walltime(tm)}seconds) -- sending them a message")
            client.signed_in(signed_in_mesg)
            client.push_to_client(signed_in_mesg)
            opts.cb?()
    )


# Record to the database a failed and/or successful login attempt.
exports.record_sign_in = (opts) ->
    opts = defaults opts,
        ip_address    : required
        successful    : required
        database      : required
        email_address : undefined
        account_id    : undefined
        remember_me   : false
    if not opts.successful
        record_sign_in_fail
            email : opts.email_address
            ip    : opts.ip_address
    else
        opts.database.log
            event : 'successful_sign_in'
            value :
                ip_address    : opts.ip_address
                email_address : opts.email_address ? null
                remember_me   : opts.remember_me
                account_id    : opts.account_id
