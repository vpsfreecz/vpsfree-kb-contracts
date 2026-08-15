;; Load the maintained vpsAdminOS container integration.
(add-to-load-path "/etc/config")
(use-modules (vpsadminos)
             (gnu)
             (gnu machine)
             (gnu machine ssh)
             (gnu services base))
(use-package-modules nss ssh)
(use-service-modules ssh)

;; These files belong to the machine from which you run guix deploy.
(define %controller-signing-key
  (local-file "/etc/guix/signing-key.pub"))
(define %root-ssh-key
  (local-file "/root/.ssh/id_ed25519.pub"))

(define %system
  (operating-system
    (host-name "guix-target")
    (timezone "Etc/UTC")
    (locale "en_US.utf8")
    (firmware '())
    (initrd-modules '())
    (kernel %ct-dummy-kernel)

    (packages (cons* nss-certs
                     %base-packages))

    (essential-services
     (modify-services
         (operating-system-default-essential-services this-operating-system)
       (delete firmware-service-type)
       (delete (service-kind %linux-bare-metal-service))))

    (bootloader %ct-bootloader)
    (file-systems %ct-file-systems)

    (services
     (cons* (service openssh-service-type
                     (openssh-configuration
                      (openssh openssh-sans-x)
                      (permit-root-login 'prohibit-password)
                      (password-authentication? #f)
                      (authorized-keys
                       `(("root" ,%root-ssh-key)))))
            (simple-service 'controller-signing-key
                            guix-service-type
                            (guix-extension
                             (authorized-keys
                              (list %controller-signing-key))))
            %ct-services))))

(define %machine
  (machine
    (operating-system %system)
    (environment managed-host-environment-type)
    (configuration
     (machine-ssh-configuration
      ;; Replace the address and host key with those of your target VPS.
      (host-name "192.0.2.3")
      (system "x86_64-linux")
      (user "root")
      (identity "/root/.ssh/id_ed25519")
      (host-key "ssh-ed25519 REPLACE_WITH_TARGET_HOST_KEY")
      (authorize? #t)
      (allow-downgrades? #f)
      ;; vpsAdminOS supplies the kernel and exposes a dummy /dev/null root.
      ;; Guix's bare-metal file-system/initrd checks cannot inspect it.
      (safety-checks? #f)))))

(list %machine)
