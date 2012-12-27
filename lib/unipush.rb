class Unipush
  attr_accessor :ios_cert_path


  def initialize(mode='production')
    if mode == 'production'
      @ios_push_url = 'gateway.push.apple.com'
      @ios_feedback_url = 'feedback.push.apple.com'
    else
      @ios_push_url = 'sandbox.gateway.push.apple.com'
      @ios_feedback_url = 'sandbox.feedback.push.apple.com'
    end
    @ios_push_port = '2195'
    @ios_feedback_port = '2196'
    @ios_cert_path = ''


    @android_auth_url = 'https://www.google.com/accounts/ClientLogin'
    @android_push_url = 'https://android.apis.google.com/c2dm/send'

    @last_error = []
  end

  def get_last_error
    @last_error.empty? ? false : @last_error
  end

  def get_unsent_messages
    @unsent_messages.nil? ? false : @unsent_messages
  end

  #message={:text=>"", :badge=>0, :newsstand=>true, :track=>true, :add=>{:param1=>1, :param2=>2}}
  def prepare_ios_message(token, message)
    json = ""
    if message[:newsstand]
      json = '{"aps":{"content-available":1}}'
      token = [token].pack('H*')
    elsif message[:text] && message[:text] != ''
      badge = message[:badge].nil? ? "0" : message[:badge].to_s
      sound = message[:sound].nil? ? "default" : message[:sound].to_s
      add_str = ""

      unless message[:add].nil?
        add_fields = []
        message[:add].each do |k, m|
          add_fields.push('"'+k.to_s+'":"'+m.gsub(/['"\\\x0]/,'\\\\\0')+'"')
        end
        add_str = ","+add_fields.join(",")
      end
      json = '{"aps":{"alert":"'+message[:text].gsub(/['"\\\x0]/,'\\\\\0')+'","badge":"'+badge+'","sound":"'+sound+'"}'+add_str+'}'
      token = [token].pack('H*')
    end

    if message[:track]
      tt = Time.now + 1.day
      mes =  [1, Random.rand, tt.to_i, 0, 32, token, 0, json.bytesize, json].pack("cNNcca*cca*")
    else
      mes = [0, 0, 32, token, 0, json.bytesize, json].pack("ccca*cca*")
    end

    mes.nil? ? false : mes
  end

  # messages = [message2, message2, ...]
  # message=[token, message={:text=>"", :badge=>0, :newsstand=>true, :track=>true, :add=>{:param1=>1, :param2=>2}}]
  def send_ios_messages(messages)
    cert_path = @ios_cert_path
    if FileTest.exist?(cert_path)
      begin
        certificate = File.read(cert_path)
        context = OpenSSL::SSL::SSLContext.new
        context.key = OpenSSL::PKey::RSA.new(certificate)
        context.cert = OpenSSL::X509::Certificate.new(certificate)
        socket = TCPSocket.new(@ios_push_url, @ios_push_port)
        ssl = OpenSSL::SSL::SSLSocket.new(socket, context)
        ssl.sync = true
        ssl.connect
        messages.each_with_index do |m, k|
          mes = prepare_ios_message(m[0], m[1])
          if mes
            ssl.write(mes)
            if ssl.pending >0 && m[1][:track]
              tmp = ssl.readline
              reply = tmp.unpack("CCN")
              @unsent_messages.push(k)
              @last_error.push("Could not send message #{k} width error: "+reply.join(", "))
            end
          else
            @unsent_messages = [] if @unsent_messages.nil?
            @unsent_messages.push(k)
          end
        end
        ssl.close
        socket.close
      rescue
        @last_error.push("Could not send messages. Exception: #{$!.inspect}")
        false
      else
        true
      end
    else
      @last_error.push("Certificate file does not exist")
      false
    end
  end

  def get_unregistered_tokens
    cert_path = @ios_cert_path
    if FileTest.exist?(cert_path)
      begin
        certificate = File.read(cert_path)
        context = OpenSSL::SSL::SSLContext.new
        context.key = OpenSSL::PKey::RSA.new(certificate)
        context.cert = OpenSSL::X509::Certificate.new(certificate)
        # получим удаленные токены
        sock = TCPSocket.new("feedback.push.apple.com", 2196)
        ssl = OpenSSL::SSL::SSLSocket.new(sock,context)
        ssl.connect
        apns_feedback = []
        while line = ssl.read(38)
          line.strip!
          f = line.unpack("NnH*")
          apns_feedback << [Time.at(f[0]), f[2]]
        end
        ssl.close
        sock.close
        # и вернем их для удаления
        ret = []
        unless apns_feedback.empty?
          apns_feedback.each do |ff|
            ret.push(ff[1])
          end
        end
        ret
      rescue
        @last_error.push("Could not get tokens. Exception: #{$!.inspect}")
        false
      end
    else
      @last_error.push("Certificate file does not exist")
      false
    end
  end


  def self.send_android_messages(app_code, messages)
    # Данные для доступа к точке отправки
    email = 'finansmag.app@gmail.com'
    password = 'developer123'
    data = "accountType=HOSTED_OR_GOOGLE&Email=#{email}&Passwd=#{password}&service=ac2dm"
    headers = { "Content-type" => "application/x-www-form-urlencoded",
                "Content-length" => "#{data.length}"}


    #  Получаем токен
    uri = URI.parse(AUTH_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    response = http.post(uri.path, data, headers)
    @auth_token = response.body.split("\n")[2].gsub("Auth=", "")

    unless @auth_token.empty?
      err_mes = []
      messages.each do |m|
        data = ['registration_id'=> m[2],
                'collapse_key' => 'c2dm',
                'data.message' => m[1]
        ]
        data = data.map{|k, v| "&#{k}=#{URI.escape(v.to_s)}"}.reduce{|k, v| k + v}
        headers = { "Authorization" => "GoogleLogin auth=#{@auth_token}",
                    "Content-type" => "application/x-www-form-urlencoded",
                    "Content-length" => "#{data.length}" }
        uri = URI.parse(PUSH_URL)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE

        result = http.post(uri.path, data, headers)

        if result.code == 200
          if result.body.split("\n")[1][0, 5].downcase == "error"
            error = result.body.split("\n")[1].gsub("Error=", "")
            case error
              when 'NotRegistered' #Пользователь удалил приложение
                Token.where(:token => m[2]).destroy
                PushMessage.find(m[0]).update_attribute(:error, (t 'errors.android.app_deleted'))
              when 'MessageTooBig' # слишком длинный текст сообщения
                PushMessage.find(m[0]).update_attribute(:error, (t 'errors.android.messagge_too_large'))
              when 'QuotaExceeded', 'DeviceQuotaExceeded' # слишком много сообщений, надо подождать
                sleep 10
                redo #Попробуем еще раз отправить
              else
                PushMessage.find(m[0]).update_attribute(:error, (t 'errors.android.common_error' + error))
            end
            err_mes.push(m[0])
          end
        else
          PushMessage.find(m[0]).update_attribute(:error, 'Error. Could not connect to c2dm server')
          return ['error', "Error. Could not connect to c2dm server"]
        end
      end
      if err_mes.size > 0
        return ['error', "Error sending #{err_mes.size} messages"]
      end
    else
      return ['error', "Authorization error. Could not receive token"]
    end
  end

end