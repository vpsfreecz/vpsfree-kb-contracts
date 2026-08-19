;; Load the maintained vpsAdminOS container integration.
(add-to-load-path "/etc/config")
(use-modules (gnu)
             (gnu machine)
             (gnu machine ssh)
             (gnu services base))
(use-service-modules ssh)

(let* ((platform-system
        (module-ref (resolve-interface '(vpsadminos))
                    '%ct-operating-system-base))
       ;; These files belong to the machine from which you run guix deploy.
       (controller-signing-key
        (local-file "/etc/guix/signing-key.pub"))
       (root-ssh-key
        (local-file "/root/.ssh/id_ed25519.pub"))
       ;; Build the service list before assigning the delayed services field.
       (user-services
        (cons
         (simple-service 'controller-signing-key
                         guix-service-type
                         (guix-extension
                          (authorized-keys
                           (list controller-signing-key))))
         (modify-services
             (operating-system-user-services platform-system)
           (openssh-service-type config =>
             (openssh-configuration
              (inherit config)
              (permit-root-login 'prohibit-password)
              (password-authentication? #f)
              (authorized-keys
               `(("root" ,root-ssh-key))))))))
       (system
        (operating-system
          (inherit platform-system)
          (host-name "guix-target")
          (timezone "Etc/UTC")
          (locale "en_US.utf8")
          (services user-services)))
       (target-machine
        (machine
          (operating-system system)
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
            (safety-checks? #f))))))
  (list target-machine))
