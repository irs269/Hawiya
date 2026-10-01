package km.hawiya.matcher;

import com.machinezoo.sourceafis.FingerprintCompatibility;
import com.machinezoo.sourceafis.FingerprintImage;
import com.machinezoo.sourceafis.FingerprintImageOptions;
import com.machinezoo.sourceafis.FingerprintMatcher;
import com.machinezoo.sourceafis.FingerprintTemplate;

/**
 * Enveloppe autour de SourceAFIS : extraction des modèles et comparaison.
 *
 * Les images attendues sont des empreintes déjà PRÉTRAITÉES par le backend
 * (niveaux de gris, crêtes sombres sur fond clair, ~500 dpi).
 */
public final class Moteur {

    private Moteur() {
    }

    /** Version du moteur : un changement impose de recalculer tous les modèles. */
    public static String version() {
        return "sourceafis-" + FingerprintCompatibility.version();
    }

    /** Image encodée (PNG, JPEG, BMP…) → modèle sérialisé. */
    public static byte[] extraire(byte[] image, double dpi) {
        var options = new FingerprintImageOptions().dpi(dpi);
        return new FingerprintTemplate(new FingerprintImage(image, options)).toByteArray();
    }

    /** Pixels bruts en niveaux de gris (ligne par ligne) → modèle sérialisé. */
    public static byte[] extraire(int largeur, int hauteur, byte[] pixels, double dpi) {
        var options = new FingerprintImageOptions().dpi(dpi);
        return new FingerprintTemplate(new FingerprintImage(largeur, hauteur, pixels, options)).toByteArray();
    }

    public static FingerprintTemplate lire(byte[] modele) {
        return new FingerprintTemplate(modele);
    }

    /**
     * Score de similarité. Repère SourceAFIS pour des empreintes de contact :
     * 40 ≈ une fausse correspondance sur 10 000. À recalibrer pour la caméra.
     */
    public static double comparer(FingerprintTemplate sonde, FingerprintTemplate candidat) {
        return new FingerprintMatcher(sonde).match(candidat);
    }
}
