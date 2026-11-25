import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Como usar").font(.title3.weight(.bold))

                VStack(alignment: .leading, spacing: 8) {
                    step(1, "Ligue o CK61 ao Mac pela porta USB TO HOST. Ele aparece como “CK Series”.")
                    step(2, "Escolha o CK61 em Entrada de áudio e em Saída de áudio.")
                    step(3, "Aperte Espaço (ou clique em Gravar), toque e aperte Espaço de novo. O loop é salvo sem o silêncio das bordas e começa a repetir.")
                    step(4, "Aperte o número de outro loop (ou Repetir): ele entra no fim da volta atual, sem pausa. Esc para.")
                }

                section("Teclado do Mac",
                        "Espaço grava e para a gravação. As teclas 1 a 9 repetem os loops 1 a 9, ↩ repete o selecionado, Esc para, ↑ ↓ escolhem o loop e ← → mudam o volume. Com ⇧ junto, a troca de loop é imediata. Para mudar as teclas ou usar ⌃⌥ com outro app na frente, abra Ajustes (⌘,).")

                section("Troca sem pausa",
                        "Com um loop tocando, escolher outro faz ele entrar exatamente no fim da volta atual, sem silêncio entre os dois (o selo “Próximo” mostra quem vem). Escolher o mesmo de novo troca na hora. O silêncio antes da primeira nota e depois da última é cortado ao salvar; em loops antigos, use “Cortar silêncio das bordas” no menu ⋯.")

                section("Sem som duplicado",
                        "O Jeske Looper não envia a entrada para a saída: a monitoração direta fica desligada. Você continua ouvindo o teclado normalmente e só o loop gravado volta pelo CK61.")

                section("USB Audio Loopback não é repetição de loop",
                        "O “USB Audio Loopback” do CK61 devolve ao computador o som que o computador envia ao teclado. Mantenha-o desligado para que o loop que está tocando não entre de novo na próxima gravação.")

                section("Permissão de entrada de áudio",
                        "Se a gravação estiver bloqueada, abra Ajustes do Sistema › Privacidade e Segurança › Microfone e ative o Jeske Looper.")

                section("Onde ficam os loops",
                        "Em Música › Jeske Looper › Loops, como arquivos WAV de 24 bits com a taxa de amostragem e o estéreo da entrada. Excluir um loop manda o arquivo para o Lixo.")
            }
            .padding(18)
        }
        .frame(width: 380, height: 560)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.brand))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
